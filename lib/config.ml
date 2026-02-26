open Core

type mapping =
  | Ticket of string
  | Skip
  | Auto_extract
[@@deriving sexp]

type category_cache = {
  options : Category.t list;
  fetched_at : string;
}
[@@deriving sexp]

type t = {
  tempo_token : string [@default ""];
  jira_email : string [@default ""];
  jira_token : string [@default ""];
  jira_base_url : string [@default ""];
  jira_account_id : string [@default ""];
  issue_ids : (string * int) list [@default []];
  account_keys : (string * string) list [@default []];  (* ticket key -> Tempo account key *)
  tempo_account_attr_key : string [@default ""];  (* cached Tempo work attribute key for Account *)
  tempo_category_attr_key : string [@default ""];  (* cached Tempo work attribute key for Category *)
  category : category_cache option [@default None];
  mappings : (string * mapping) list [@default []];
}
[@@deriving sexp]

(* TODO: Consider proper schema migrations if config format changes frequently *)

let default_path () =
  let home = Sys.getenv_exn "HOME" in
  home ^/ ".config" ^/ "watsup" ^/ "config.sexp"

let empty = {
  tempo_token = "";
  jira_email = "";
  jira_token = "";
  jira_base_url = "";
  jira_account_id = "";
  issue_ids = [];
  account_keys = [];
  tempo_account_attr_key = "";
  tempo_category_attr_key = "";
  category = None;
  mappings = [];
}

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

let get_issue_id config ticket =
  List.Assoc.find config.issue_ids ~equal:String.equal ticket

let set_issue_id config ticket issue_id =
  let issue_ids =
    List.Assoc.add config.issue_ids ~equal:String.equal ticket issue_id
  in
  { config with issue_ids }

let get_account_key config ticket =
  List.Assoc.find config.account_keys ~equal:String.equal ticket

let set_account_key config ticket account_key =
  let account_keys =
    List.Assoc.add config.account_keys ~equal:String.equal ticket account_key
  in
  { config with account_keys }

let%expect_test "config round trip" =
  let path = Stdlib.Filename.temp_file "watsup_test" ".sexp" in
  let config =
    { empty with
      tempo_token = "test-token";
      jira_email = "user@example.com";
      issue_ids = [("LOG-1", 12345)];
      mappings = [ ("breaks", Skip); ("proj", Ticket "LOG-16") ];
    }
  in
  save ~path config |> Or_error.ok_exn;
  let loaded = load ~path |> Or_error.ok_exn in
  print_s [%sexp (loaded.tempo_token : string)];
  [%expect {| test-token |}];
  print_s [%sexp (loaded.jira_email : string)];
  [%expect {| user@example.com |}];
  print_s [%sexp (loaded.issue_ids : (string * int) list)];
  [%expect {| ((LOG-1 12345)) |}];
  print_s [%sexp (loaded.mappings : (string * mapping) list)];
  [%expect {| ((breaks Skip) (proj (Ticket LOG-16))) |}];
  Core_unix.unlink path

let%expect_test "get_mapping" =
  let config =
    { empty with
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

let%expect_test "get_issue_id and set_issue_id" =
  let config = empty in
  print_s [%sexp (get_issue_id config "LOG-1" : int option)];
  [%expect {| () |}];
  let config = set_issue_id config "LOG-1" 12345 in
  let config = set_issue_id config "LOG-2" 67890 in
  print_s [%sexp (get_issue_id config "LOG-1" : int option)];
  [%expect {| (12345) |}];
  print_s [%sexp (get_issue_id config "LOG-2" : int option)];
  [%expect {| (67890) |}]
