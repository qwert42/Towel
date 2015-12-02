OPAM_DEPENDS="ocamlfind batteries sha stdint"

sudo apt-get update -qq
sudo apt-get install -qq ocaml ocaml-native-compilers camlp4-extra opam
export OPAMYES=1
opam init
opam install ${OPAM_DEPENDS}
eval `opam config env`
sudo apt-get install rbenv
rbenv install 2.2.3
rbenv local 2.2.3
sudo apt-get install python3
waf configure --native --tvm --compiler build test