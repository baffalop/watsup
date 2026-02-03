open Core

type mapping =
  | Ticket of string
  | Skip
  | Auto_extract
[@@deriving sexp]

type category_cache = {
  selected : string;
  options : string list;
  fetched_at : string;
}
[@@deriving sexp]

type t = {
  tempo_token : string;
  category : category_cache option;
  mappings : (string * mapping) list;
}
[@@deriving sexp]

let default_path () =
  let home = Sys.getenv_exn "HOME" in
  home ^/ ".config" ^/ "watsup" ^/ "config.sexp"

let empty = { tempo_token = ""; category = None; mappings = [] }

let load ~path =
  if Stdlib.Sys.file_exists path then
    try
      let contents = In_channel.read_all path in
      let sexp = Sexp.of_string contents in
      Ok (t_of_sexp sexp)
    with
    | exn -> Or_error.error_string (Exn.to_string exn)
  else Ok empty

let save ~path config =
  try
    let dir = Filename.dirname path in
    Core_unix.mkdir_p dir;
    let sexp = sexp_of_t config in
    Out_channel.write_all path ~data:(Sexp.to_string_hum sexp);
    Ok ()
  with
  | exn -> Or_error.error_string (Exn.to_string exn)

let get_mapping config project =
  List.Assoc.find config.mappings ~equal:String.equal project

let set_mapping config project mapping =
  let mappings =
    List.Assoc.add config.mappings ~equal:String.equal project mapping
  in
  { config with mappings }

let%expect_test "config round trip" =
  let path = Stdlib.Filename.temp_file "watsup_test" ".sexp" in
  let config =
    {
      tempo_token = "test-token";
      category = None;
      mappings = [ ("breaks", Skip); ("proj", Ticket "LOG-16") ];
    }
  in
  save ~path config |> Or_error.ok_exn;
  let loaded = load ~path |> Or_error.ok_exn in
  print_s [%sexp (loaded.tempo_token : string)];
  [%expect {| test-token |}];
  print_s [%sexp (loaded.mappings : (string * mapping) list)];
  [%expect {| ((breaks Skip) (proj (Ticket LOG-16))) |}];
  Core_unix.unlink path

let%expect_test "get_mapping" =
  let config =
    {
      tempo_token = "";
      category = None;
      mappings = [ ("proj", Ticket "LOG-16"); ("breaks", Skip) ];
    }
  in
  print_s [%sexp (get_mapping config "proj" : mapping option)];
  [%expect {| ((Ticket LOG-16)) |}];
  print_s [%sexp (get_mapping config "unknown" : mapping option)];
  [%expect {| () |}]

let%expect_test "set_mapping" =
  let config = empty in
  let config = set_mapping config "proj" (Ticket "LOG-16") in
  let config = set_mapping config "breaks" Skip in
  print_s [%sexp (config.mappings : (string * mapping) list)];
  [%expect {| ((breaks Skip) (proj (Ticket LOG-16))) |}]
