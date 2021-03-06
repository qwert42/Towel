open Common
open Parser
open Exc
open Stdint
open Ast

let _ =
  let lexbuf = Lexing.from_channel stdin in
  try
    let rec accum acc =
      let token = Scanner.token lexbuf in
      (match token with
         LITERAL(l) -> let s = match l.value_content with
             VFixedInt(i) -> "some fixed int"
           | VUFixedInt(i) -> "some unsigned fixed int"
           | VInt(i) -> "some int"
           | _ -> "some literal"
             in accum (s::acc)
       | NAME(n) -> accum ((pname_stringify n)::acc)
       | BQUOTE -> accum ("`"::acc)
       | COMMA -> accum ("COMMA,"::acc)
       | SEMICOLON -> accum (";"::acc)
       | TERMINATOR(x) -> (match x with
             Ast.Period -> "."::acc
           | Ast.EOF -> "eof"::acc)
       | LPAREN -> accum ("("::acc)
       | RPAREN -> accum (")"::acc)
       | LBRACKET -> accum ("["::acc)
       | RBRACKET -> accum ("]"::acc)
       | SLASH -> accum ("\\"::acc)
       | AT -> accum ("@"::acc)
       | LBRACE -> accum ("{"::acc)
       | RBRACE -> accum ("}"::acc)
       | BIND -> accum ("bind"::acc)
       | IFT -> accum ("ift"::acc)
       | FUNCTION -> accum ("fun"::acc)
       | _ -> accum (""::acc))
      in let xs = accum [] in List.iter print_endline (List.rev xs)
  with LexicalError(s, ln, b) ->
    Printf.printf "(%d,%d) Lexical error: %s.\n" ln b s
