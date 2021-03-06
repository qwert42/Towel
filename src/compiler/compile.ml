open Switches;;
open Cseg;;
open Common;;
open Stdint;;
open Exp;;
open Tasm_ast;;
open Config;;
open Scoping;;

let global_fn_id = ref "";;
let global_snippets = ref [];;

type ctx_t = {
  sw: switches; mode: int; (* 1 for push; 2 for pat *)
  is_body: bool; is_backquoted: bool;
  scp_stk: scope_t list; ext_scope_meta: external_scope_t;
};;

let __unique64 = Common.counter ();;
let uniq64 x = Printf.sprintf ":%s-%s" !global_fn_id @@ tu64 @@ __unique64 x;;

let aggregate = List.fold_left (|~~|) cnil;;

let negate_label l = l ^ "!";;

let lmap = List.map;;
let flmap s f = List.map f s;;

let atom_dict = Hashtbl.create 512;;
let atom_repr_tick = Common.counter ();;
Hashtbl.replace atom_dict "false" Uint64.zero;;
Hashtbl.replace atom_dict "true" @@ atom_repr_tick ();;

let mod_uid, _ = name_repr_tick_gen ();;

let name_uid, _ = name_repr_tick_gen ();;
(* 2**64 names should surely be enough. Or I'll say it's more than enough. And
   may cause problem in bytecode generation.
   The reasons that I'm reluctant to change it to int or uint16 are that
   (1) I'm so lazy;
   (2) There isn't int or uint16 in TAsm, there is only uint64, int64 and big_int.
 *)

let ext_scope_tick = Common.counter ();;
ignore (ext_scope_tick ());; (* Module id: 0 for self, 1 for main,
                                2 .. for ext modules. *)

let fun_tick = Common.counter ();;

let (--) x y = Printf.sprintf "%s-%s" x y;;
let (^-) x y = Printf.sprintf "%d-%s" x y;;

let exp_scope:(string, name_t) Hashtbl.t = Hashtbl.create 512;;
let export ctx ns =
  let _export_one n =
    Hashtbl.replace exp_scope n.Ast.name_repr @@ lookup_name ctx.scp_stk n;
    line (EXPORT(ArgLit(VUFixedInt(lookup_name ctx.scp_stk n))))
  in aggregate (List.map _export_one ns);

type callback_arg_t = Words of Ast.word list
                    | Word of Ast.word;;
type inst_ctx_t = {pre: (callback_arg_t -> asm);
                   post: (callback_arg_t -> asm)};;
let inst_nil_ctx = {pre = (fun _ -> cnil);
                    post = (fun _ -> cnil)};;

let find_closure ctx tree =
  (* This function is trivial. It literally traverse the given subtree of the AST,
     mimics all the scoping behavior, and tries to figure out what's in the local
     scope and what's not.
     Yes, a crippled version of g_word. *)
  (* Only find_closure when you finish generating all the code. Because you have
     to know all the names bound in current scope to know what to capture.
     OR MAYBE NOT. *)
  let outer_scope = ctx.scp_stk

  in let table = Hashtbl.create 512
  in let add_name local_scps pn =
    let ns = match pn with
        Ast.NRegular(ns) -> ns
      | Ast.NTailCall(ns) -> ns
    in if List.length ns = 1
    then try if (Uint64.compare
                   (* Cope with is_DEBUG. *)
               (lookup_name local_scps (List.hd ns)) Uint64.zero) <> 0
    (* Search in local scopes to see if the names exists, e.g.
       fun A,
         fun B,
           bind C D
           then (C)
       if we are finding closure about the outmost function,
       A is local, B is local, C is local, D is nonlocal,
       or A, B, C appear bound, D appears free.

       See also the comment at Ast.WSequence. *)
        then (* Do nothing. *) ()
        else (* Outside of current scope, add to the closure set. *)
          Hashtbl.replace table
            ((lookup_name outer_scope (List.hd ns)), Uint64.zero) 1
      with Exc.NameNotFoundError(_) ->
        Hashtbl.replace table
          ((lookup_name outer_scope (List.hd ns)), Uint64.zero) 1

    else (* See nvm.ml:218 for why we don't need to put ext names in closure.
            Hashtbl.replace table
            (lookup_ext_name ctx.ext_scope_meta ns) 1 *)
      ()

  in let rec __find_in locals is_body =
       function
        Ast.WName(pn) -> add_name locals pn
      | Ast.WLiteral(pv) ->
        (match pv.Ast.value_content with
          Ast.VList(wl) -> List.iter (__find_in locals false) wl
        | Ast.VTuple(wl) -> List.iter (__find_in locals false) wl
        | _ -> ()) (* No name references in other kind of literals. *)
      | Ast.WBackquote(bq) ->
        (match bq with
           Ast.BQName(n) -> add_name locals n
         | Ast.BQSeq(seq) -> __find_in locals false (Ast.WSequence(seq))
         | Ast.BQValue(v) -> __find_in locals false (Ast.WLiteral(v))
         | Ast.BQBackquote(b) -> __find_in locals false (Ast.WBackquote(b)))
      | Ast.WSequence(seq) ->
        (match seq with
         (* What if you do
            fun A,
              (B
               fun C,
                 bind B D
                 also E F
                 then (C B)
               B
               E)
            B should still be in the closure set. So should E. *)
           Ast.Sequence(ws) ->
           let new_scope = locals
           in List.iter (__find_in new_scope false) ws
         | Ast.SharedSequence(ws) ->
           (* If it's a shared sequence, do the same as a opt'ed sequence. *)
           List.iter (__find_in locals false) ws)
      | Ast.WControl(ctrl) ->
        (match ctrl with
           Ast.CtrlSeqIfForm(ifs) ->
           (match ifs with
              Ast.IfGEZ(ib) | Ast.IfGZ(ib) | Ast.IfLEZ(ib)
            | Ast.IfLZ(ib) | Ast.IfEmpty(ib) | Ast.IfNonEmpty(ib)
            | Ast.IfEZ(ib) | Ast.IfNEZ(ib) | Ast.IfT(ib) | Ast.IfF(ib) ->
              (match ib with
                 Ast.IfBody(ib1, ib2) ->
                 __find_in locals true ib1;
                 __find_in locals true ib2)))
      | Ast.WFunction(f) ->
        (match f with
           Ast.Function(args, body)
         | Ast.BQFunction(args, body) ->
           let new_locals = push_scope locals
           in List.iter (function
                 Ast.ArgDef(pn) ->
                 push_name new_locals pn Uint64.one) args;
           __find_in new_locals true body)
      | Ast.WBind(Ast.BindThen(bs, bt)) ->
        let new_locals = push_scope locals
        in List.iter (function
              Ast.BindBody(pn, b) -> push_name new_locals pn Uint64.one;
              __find_in new_locals false b) bs;
        __find_in new_locals true bt
      | Ast.WImport(_) -> ()
      | Ast.WExport(_) -> ()
  in __find_in [] ctx.is_body tree;
  table;;

let rec g_lit ctx inst_ctx lit =
  match lit.Ast.value_content with
    Ast.VAtom(atom) ->
    let repr =
      (try Hashtbl.find atom_dict atom.Ast.atom_name
       with Not_found ->
         let r = atom_repr_tick ()
         in Hashtbl.add atom_dict atom.Ast.atom_name r; r)
    in (inst_ctx.pre (Word(Ast.WLiteral(lit))))
       |~~| (line (PUSH_LIT(ArgLit(VAtom(repr)))))
       |~~| (inst_ctx.post (Word(Ast.WLiteral(lit))))
  | Ast.VFixedInt(i) ->
    (inst_ctx.pre (Word(Ast.WLiteral(lit))))
    |~~| (line (PUSH_LIT(ArgLit(VFixedInt(i)))))
    |~~| (inst_ctx.post (Word(Ast.WLiteral(lit))))
  | Ast.VUFixedInt(u) ->
    (inst_ctx.pre (Word(Ast.WLiteral(lit))))
    |~~| (line (PUSH_LIT(ArgLit(VUFixedInt(u)))))
    |~~| (inst_ctx.post (Word(Ast.WLiteral(lit))))
  | Ast.VInt(i) ->
    (inst_ctx.pre (Word(Ast.WLiteral(lit))))
    |~~| (line (PUSH_LIT(ArgLit(VInt(i)))))
    |~~| (inst_ctx.post (Word(Ast.WLiteral(lit))))
  | Ast.VFloat(f) ->
    (inst_ctx.pre (Word(Ast.WLiteral(lit))))
    |~~| (line (PUSH_LIT(ArgLit(VFloat(f)))))
    |~~| (inst_ctx.post (Word(Ast.WLiteral(lit))))
  | Ast.VString(s) ->
    (inst_ctx.pre (Word(Ast.WLiteral(lit))))
    |~~| (line (PUSH_LIT(ArgLit(VString(s)))))
    |~~| (inst_ctx.post (Word(Ast.WLiteral(lit))))
  | Ast.VList(wl) ->
    (inst_ctx.pre (Words(wl)))
    |~~| (line (PUSH_LNIL))
    |~~| inst_ctx.post (Words(wl))
    |~~| (let r = flmap wl (g_word ctx inst_nil_ctx)
          in aggregate r)
    |~~| (line END_LIST)
  | Ast.VTuple(wl) ->
    (inst_ctx.pre (Words(wl)))
    |~~| (line (PUSH_TNIL))
    |~~| inst_ctx.post (Words(wl))
    |~~| (let r = flmap wl (g_word ctx inst_nil_ctx)
          in aggregate r)
    |~~| (line END_TUPLE)

and g_import ctx imp =
  let is_explicit, ss = match imp with Ast.ExplicitImport(ss) -> true, ss
                                     | Ast.ImplicitImport(ss) -> false, ss

  in let bindings = ref []

  in let push_into_scope ext_scope =
       let sorted_ext_scope =
         List.sort (fun x y -> Pervasives.compare (snd x) (snd y))
         @@ Hashtbl.fold (fun k v acc -> (k, v)::acc) ext_scope []
       in List.iter (fun x ->
           let k, v = x
           in push_name ctx.scp_stk {Ast.name_repr = k}
             (name_uid k)) sorted_ext_scope

  in let rec find_module mod_str = function
        path::rest ->
        let possible_mod_path = Filename.concat path (mod_str ^ ".e")
        in if BatSys.file_exists possible_mod_path
        then let ext_scope = open_export possible_mod_path
          in begin
            push_ext_scope ctx.ext_scope_meta ext_scope
              (mod_uid mod_str) mod_str;
            if not is_explicit
            then begin
              bindings := Hashtbl.fold (fun name uid acc ->
                  ((line (PUSH_NAME(ArgLit(VUFixedInt(uid)),
                                    ArgLit(VUFixedInt(mod_uid mod_str)))))
                   |~~| (line (BIND(ArgLit(VUFixedInt(name_uid name))))))::acc)
                  ext_scope [];
              push_into_scope ext_scope
            end else ()
          end

        else find_module mod_str rest
      | [] -> failwith (Printf.sprintf "Requested module `%s' not found." mod_str)

  in let () = List.iter (fun x -> find_module x Config.libpaths) ss
  in List.fold_left (|~~|) cnil
  @@ lmap (fun x ->
      (line (PUSH_LIT(ArgLit(VString(x)))))
      |~~| (line (IMPORT(ArgLit(VUFixedInt(mod_uid x)))))
      |~~| (if is_explicit
            then cnil
            else aggregate !bindings)) ss

and g_bind ctx =
  let new_scps = push_scope ctx.scp_stk
  in let _g_bind_body =
    function
      Ast.BindBody(pn, b) ->
      (push_name new_scps pn @@ name_uid pn.Ast.name_repr);
      (cnil
       |~~| (g_word {ctx with is_body = false;
                              is_backquoted = false;
                              scp_stk = new_scps}
               {inst_nil_ctx
                with post =
                       fun _ -> line (BIND(ArgLit(VUFixedInt(
                           lookup_name new_scps pn))))}
               b))
      (* Cannot do compile-time stack indexing, i.e. giving names the stack index,
         because you don't know what will come out of the calculation in `b'. *)

  in function
      Ast.BindThen(bs, b) ->
      let bind_inst = aggregate (lmap _g_bind_body bs)
      in let then_inst = g_word {ctx with is_body = true; is_backquoted = false;
                                          scp_stk = new_scps}
             inst_nil_ctx b
      in (line PUSH_SCOPE) |~~| bind_inst |~~| then_inst |~~| (line POP_SCOPE)

and g_name ctx inst_ctx n =
  let get_args ns = if List.length ns = 1
    then ArgLit(VUFixedInt(lookup_name ctx.scp_stk (List.hd ns))),
         ArgLit(VUFixedInt(Uint64.zero))
    else let n_uid, es_uid = lookup_ext_name ctx.ext_scope_meta ns
      in ArgLit(VUFixedInt(n_uid)), ArgLit(VUFixedInt(es_uid))
  in let inst = match n with
        Ast.NRegular(ns) ->
        let arg1, arg2 = get_args ns
        in if ctx.is_backquoted
        then line (PUSH_NAME(arg1, arg2))
        else line (EVAL_AND_PUSH(arg1, arg2))

      | Ast.NTailCall(ns) ->
        let arg1, arg2 = get_args ns
        in if ctx.is_backquoted
        then line (PUSH_NAME(arg1, arg2)) (* This is a weird case. *)
        else line (EVAL_TAIL(arg1, arg2))
  in cnil
     |~~| inst_ctx.pre (Word(Ast.WName(n)))
     |~~| inst
     |~~| inst_ctx.post (Word(Ast.WName(n)))

and g_ctrl ctx =
  function
    Ast.CtrlSeqIfForm(i) -> g_if ctx i

and g_if ctx inst =
  let _UID = uniq64 ()
  in let brancht_id = _UID
  in let branchf_id = negate_label _UID
  in let is_hungry = sw_hungry_if ctx.sw

  in let if_body_ = function
        Ast.IfBody(bt, bf) ->
        let brancht = g_word {ctx with is_body = true;
                                       is_backquoted = false} inst_nil_ctx bt
        in let branchf = g_word {ctx with is_body = true;
                                          is_backquoted = false} inst_nil_ctx bf
        in let if_end_id = Printf.sprintf "%s-end" _UID

        in (put_label [brancht_id]) |~~| brancht
           |~~| (line (JUMP(ArgLabel(Label(if_end_id)))))
           |~~| (put_label [branchf_id]) |~~| branchf
           |~~| (put_label [if_end_id])

  in let _g_body ib i =
       cnil |~~| (line i) |~~| (if_body_ ib)

  in let parse = let lbl = ArgLabel(Label(branchf_id))
       in function
           Ast.IfGEZ(ib) -> ib, (if is_hungry then HJLZ(lbl) else JLZ(lbl))
         | Ast.IfGZ(ib) -> ib, if is_hungry then HJLEZ(lbl) else JLEZ(lbl)
         | Ast.IfLEZ(ib) -> ib, if is_hungry then HJGZ(lbl) else JGZ(lbl)
         | Ast.IfLZ(ib) -> ib, if is_hungry then HJGEZ(lbl) else JGEZ(lbl)
         | Ast.IfEZ(ib) -> ib, if is_hungry then HJNEZ(lbl) else JNEZ(lbl)
         | Ast.IfNEZ(ib) -> ib, if is_hungry then HJEZ(lbl) else JEZ(lbl)
         | Ast.IfT(ib) -> ib, if is_hungry then HJF(lbl) else JF(lbl)
         | Ast.IfF(ib) -> ib, if is_hungry then HJT(lbl) else JT(lbl)
         | Ast.IfEmpty(ib) -> ib, JNE(lbl)
         | Ast.IfNonEmpty(ib) -> ib, if is_hungry then HJE(lbl) else JE(lbl)

  in let body, ins = parse inst
  in _g_body body ins

and g_backquote ctx inst_ctx =
  let new_ctx = {ctx with is_backquoted = true}
  in function
    Ast.BQValue(pv) -> g_lit new_ctx inst_ctx pv
  | Ast.BQName(n) -> g_name new_ctx inst_ctx n
  | Ast.BQSeq(seq) -> g_seq new_ctx inst_ctx seq
  | Ast.BQBackquote(bq) -> g_backquote ctx inst_ctx bq

and g_seq ctx inst_ctx seq =
  let _UID = uniq64 ()

  in let seq_st_id = Printf.sprintf "%s-st" _UID
  in let seq_end_id = Printf.sprintf "%s-end" _UID
  in let seq_real_end_id = if _UID = "na" then ""
       else Printf.sprintf "%s-real-end" _UID

  in let is_shared = match seq with
        Ast.Sequence(_) -> false
      | Ast.SharedSequence(_) -> true

  in let opt_cs what =
       if sw_opt_seq ctx.sw
       then if ctx.is_body
       (* Optimize out some of the boilerplate code based on the current
          switches settings. *)
         then cnil
         else what
       else what

  in let seq_preamble =
       let _x = if not is_shared
         then (put_label [seq_st_id])
              |~~| (line PUSH_STACK)
              |~~| (line PUSH_SCOPE)
         else put_label [seq_st_id]
       in opt_cs _x

  in let seq_postamble =
       let _x = if not is_shared
         then (put_label [seq_end_id])
              |~~| (line POP_SCOPE)
              |~~| (line RET)
         else (put_label [seq_end_id])
              |~~| (line SHARED_RET)
       in (opt_cs (_x |~~| (put_label [seq_real_end_id])))

  in let body, scp_stk = match seq with
        Ast.Sequence(s) -> s, ctx.scp_stk
      | Ast.SharedSequence(s) -> s, ctx.scp_stk

  in let lead_inst = if ctx.is_backquoted
       then (line (PUSH_FUN(ArgLabel(Label(seq_st_id)))))
       else (line (CALL(ArgLabel(Label(seq_st_id)))))
  in let body_insts = aggregate (lmap (g_word {ctx with is_body = false;
                                                        is_backquoted = false;
                                                        scp_stk = scp_stk}
                                         inst_nil_ctx) body)
  in let seq_insts =
       cnil
       |~~| seq_preamble
       |~~| (if ctx.is_backquoted
             then (line INSTALL)
             else cnil)
       |~~| body_insts
       |~~| seq_postamble

  in let closure = if ctx.is_backquoted
       then find_closure ctx (Ast.WSequence(seq))
       (* As it turns out, ctx.scp_stk can totally represent the state of
          the scope stack before we enter this sequence context. *)
       else Hashtbl.create 1
  in let closure_insts =
       (Hashtbl.fold (fun k v acc ->
           let nid, esid = k
           in acc |~~| line (CLOSURE(ArgLit(VUFixedInt(nid)))))
           closure cnil)

  in let () = if ctx.is_body
       then ()
       else global_snippets := seq_insts::(!global_snippets)

  in let body_main = if ctx.is_body
       then seq_insts
       else cnil
       (* We cannot put shared seq_insts in global_snippets like functions,
          because shared sequences don't have return instruction to go back
          to where we began. *)

  in inst_ctx.pre (Word(Ast.WSequence(seq)))
     |~~| (opt_cs lead_inst)
     |~~| inst_ctx.post (Word(Ast.WSequence(seq)))
     |~~| closure_insts
     |~~| body_main

and g_fun ctx inst_ctx fun_ =
  let _UID = uniq64 ()
  in let st_label = _UID -- "st"
  in let end_label = _UID -- "end"
  in let real_end_label = _UID -- "real-end"

  in let preamble = (put_label [st_label])
                    |~~| (line (if sw_share_stack ctx.sw
                            then SHARE_STACK
                            else PUSH_STACK))
                    |~~| (line PUSH_SCOPE)
  in let scp_stk = push_scope ctx.scp_stk
         (* A function invocation automatically pushes a scope (for its arguments),
            so no need to explicitly write a push-scope. *)
  in let _g_arg_def = function
        Ast.ArgDef(pn) ->
        push_name scp_stk pn @@ name_uid pn.Ast.name_repr;
        line (FUN_ARG(ArgLit(VUFixedInt(lookup_name scp_stk pn))))

  in let _g_fun arg_defs body is_backquoted =
       let closure = if is_backquoted
         then find_closure ctx (Ast.WFunction(fun_))
         else Hashtbl.create 1
       in let closure_insts =
            Hashtbl.fold (fun k v acc ->
                let nid, esid = k
                in acc |~~| line (CLOSURE(ArgLit(VUFixedInt(nid)))))
              closure cnil

       in let fun_inst = if is_backquoted
            then PUSH_FUN(ArgLabel(Label(st_label)))
            else CALL(ArgLabel(Label(st_label)))

       in let main = cnil
                  |~~| inst_ctx.pre (Word(Ast.WFunction(fun_)))
                  |~~| (line fun_inst)
                  |~~| inst_ctx.post (Word(Ast.WFunction(fun_)))
                  |~~| closure_insts

       in let fun_args = aggregate @@ List.rev @@ lmap _g_arg_def arg_defs
       in let body_inst = g_word {ctx with is_body = true;
                                           scp_stk = scp_stk;
                                           is_backquoted = false}
              inst_nil_ctx body
       in let snippet = cnil
                        |~~| preamble
                        |~~| (line INSTALL)
                        |~~| fun_args
                        |~~| (line SWEEP)
                        |~~| body_inst
                        |~~| (cline [end_label] (Some(POP_SCOPE)))
                        |~~| (line RET)
                        |~~| (put_label [real_end_label])
       in global_snippets := snippet::(!global_snippets);
       main
  in match fun_ with
      Ast.BQFunction(arg_defs, body) -> _g_fun arg_defs body true
    | Ast.Function(arg_defs, body) -> _g_fun arg_defs body false

and g_word ctx inst_ctx = function
    Ast.WLiteral(pv) -> g_lit ctx inst_ctx pv
  | Ast.WName(n) -> g_name ctx inst_ctx n
  | Ast.WBackquote(bq) -> g_backquote ctx inst_ctx bq
  | Ast.WSequence(seq) -> g_seq ctx inst_ctx seq
  | Ast.WControl(ctrl) -> g_ctrl ctx ctrl
  | Ast.WFunction(f) -> g_fun ctx inst_ctx f
  | Ast.WBind(b) -> g_bind ctx b
  | Ast.WImport(is) -> g_import ctx is
  | Ast.WExport(ns) -> export ctx ns

let compile cst fn sw =
  let scope_stack_init = push_scope []

  in global_fn_id := fn;
  let aLL_THE_REST_OF_THAT =
       lmap (g_word {sw = sw; mode = 1; scp_stk = scope_stack_init;
                     is_body = true; is_backquoted = false;
                     ext_scope_meta = ExtScope(Hashtbl.create 512,
                                               Hashtbl.create 512,
                                               Uint64.zero)}
               inst_nil_ctx)
         (match cst with
            Ast.Sentence(ws) -> ws)
  in (cnil
     |~~| (line PUSH_STACK)
     |~~| (line PUSH_SCOPE)
     |~~| (aggregate aLL_THE_REST_OF_THAT)
     |~~| (line TERMINATE)
     |~~| (aggregate !global_snippets)),
     exp_scope
