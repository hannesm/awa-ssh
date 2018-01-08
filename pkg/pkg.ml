#!/usr/bin/env ocaml
#use "topfind"
#require "topkg"
open Topkg

let () =
  let opams =
    [ Pkg.opam_file "opam"
        ~lint_deps_excluding:(Some ["ppx_tools" ; "ppx_sexp_conv"]) ]
  in

  Pkg.describe ~opams "awa" @@ fun c ->
  let exts = Exts.(cmx @ library @ exts [".cmi" ; ".cmt" ]) in
  Ok [
    (* Awa library *)
    Pkg.lib ~exts "lib/awa" ;
    Pkg.test "lib/test/test";
    (* Drivers *)
    Pkg.lib ~exts "drivers/driver";
    Pkg.test ~run:false "drivers/test/awa_test_server"
  ]
