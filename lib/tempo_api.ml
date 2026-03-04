open Core

type creds = {
  token : string;
  author_account_id : string;
}

let tempo_headers ~creds = [
  ("Authorization", sprintf "Bearer %s" creds.token);
  ("Accept", "application/json");
]

(* Discover work attribute keys from Tempo (Account and Category) *)
let parse_work_attribute_keys_json json =
  match Yojson.Safe.Util.(json |> member "results") with
  | `List attrs ->
    let find_key ~substring =
      List.find_map attrs ~f:(fun attr ->
        let name = Yojson.Safe.Util.(attr |> member "name" |> to_string) in
        let key = Yojson.Safe.Util.(attr |> member "key" |> to_string) in
        if String.is_substring (String.lowercase name) ~substring
        then Some key else None)
    in
    Ok (find_key ~substring:"account", find_key ~substring:"category")
  | _ -> Error "Unexpected work-attributes response format"

let fetch_work_attribute_keys ~creds =
  let url = "https://api.tempo.io/4/work-attributes" in
  let headers = tempo_headers ~creds in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    parse_work_attribute_keys_json (Yojson.Safe.from_string response.body)
  else
    Error (sprintf "Tempo work-attributes error (%d): %s" response.status response.body)

(* Parse category options from a Tempo work attribute response *)
let parse_category_options_json json =
  let names_map = match Yojson.Safe.Util.(json |> member "names") with
    | `Assoc pairs ->
      List.filter_map pairs ~f:(fun (k, v) ->
        match v with `String s -> Some (k, s) | _ -> None)
    | _ -> []
  in
  let values = match Yojson.Safe.Util.(json |> member "values") with
    | `List vs ->
      List.filter_map vs ~f:(fun v ->
        match v with
        | `String key ->
          let name = List.Assoc.find names_map ~equal:String.equal key
            |> Option.value ~default:key in
          Some (key, name)
        | _ -> None)
    | _ -> []
  in
  if List.is_empty values then Error "No Tempo category values found"
  else values
  |> List.map ~f:(fun (value, name) -> Category.make ~value ~name)
  |> Result.return

let fetch_category_options ~creds ~attr_key =
  let url = sprintf "https://api.tempo.io/4/work-attributes/%s" attr_key in
  let headers = tempo_headers ~creds in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    parse_category_options_json (Yojson.Safe.from_string response.body)
  else
    Result.fail @@ sprintf "Tempo work-attribute lookup error (%d): %s"
      response.status response.body

(* Look up Tempo account key by numeric ID *)
let fetch_account_key ~creds ~account_id =
  let url = sprintf "https://api.tempo.io/4/accounts/%s" account_id in
  let headers = tempo_headers ~creds in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    let json = Yojson.Safe.from_string response.body in
    match Yojson.Safe.Util.member "key" json with
    | `String key -> Ok key
    | _ -> Error "key not found in Tempo account response"
  else
    Error (sprintf "Tempo account lookup error (%d): %s" response.status response.body)

let build_worklog_json ~issue_id ~author_account_id ~duration_seconds ~date ~description ~attributes =
  let open Yojson.Safe in
  let base = [
    ("issueId", `Int issue_id);
    ("authorAccountId", `String author_account_id);
    ("timeSpentSeconds", `Int duration_seconds);
    ("startDate", `String date);
    ("startTime", `String "09:00:00");
    ("description", `String description);
  ] in
  let fields = match attributes with
    | [] -> base
    | attrs ->
      base @ [("attributes", `List (
        List.map attrs ~f:(fun (key, value) ->
          `Assoc [("key", `String key); ("value", `String value)])
      ))]
  in
  to_string (`Assoc fields)

let post_worklog ~creds ~issue_id ~duration ~date ~description ~attributes =
  let url = "https://api.tempo.io/4/worklogs" in
  let headers = [
    ("Authorization", sprintf "Bearer %s" creds.token);
    ("Content-Type", "application/json");
  ] in
  let duration_seconds = Duration.to_seconds duration in
  let body = build_worklog_json ~issue_id ~author_account_id:creds.author_account_id ~duration_seconds ~date ~description ~attributes in
  Io.http_post ~url ~headers ~body

let%expect_test "build_worklog_json: without attributes" =
  let json = build_worklog_json ~issue_id:123 ~author_account_id:"abc"
    ~duration_seconds:3600 ~date:"2026-02-03" ~description:"test" ~attributes:[] in
  print_endline json;
  [%expect {| {"issueId":123,"authorAccountId":"abc","timeSpentSeconds":3600,"startDate":"2026-02-03","startTime":"09:00:00","description":"test"} |}]

let%expect_test "build_worklog_json: with attributes" =
  let json = build_worklog_json ~issue_id:123 ~author_account_id:"abc"
    ~duration_seconds:3600 ~date:"2026-02-03" ~description:""
    ~attributes:[("_Account_", "ACCT-1"); ("_Category_", "dev")] in
  print_endline json;
  [%expect {| {"issueId":123,"authorAccountId":"abc","timeSpentSeconds":3600,"startDate":"2026-02-03","startTime":"09:00:00","description":"","attributes":[{"key":"_Account_","value":"ACCT-1"},{"key":"_Category_","value":"dev"}]} |}]

let%expect_test "parse_work_attribute_keys_json: both found" =
  let json = Yojson.Safe.from_string {|{
    "results": [
      {"name": "Account", "key": "_Account_"},
      {"name": "Category", "key": "_Category_"},
      {"name": "Other", "key": "_Other_"}
    ]
  }|} in
  let result = parse_work_attribute_keys_json json in
  (match result with
   | Ok (account, category) ->
     printf "account=%s category=%s\n"
       (Option.value account ~default:"none")
       (Option.value category ~default:"none")
   | Error e -> printf "error: %s\n" e);
  [%expect {| account=_Account_ category=_Category_ |}]

let%expect_test "parse_work_attribute_keys_json: none found" =
  let json = Yojson.Safe.from_string {|{
    "results": [{"name": "Other", "key": "_Other_"}]
  }|} in
  let result = parse_work_attribute_keys_json json in
  (match result with
   | Ok (account, category) ->
     printf "account=%s category=%s\n"
       (Option.value account ~default:"none")
       (Option.value category ~default:"none")
   | Error e -> printf "error: %s\n" e);
  [%expect {| account=none category=none |}]

let%expect_test "parse_category_options_json: valid" =
  let json = Yojson.Safe.from_string {|{
    "names": {"dev": "Development", "ops": "Operations"},
    "values": ["dev", "ops"]
  }|} in
  (match parse_category_options_json json with
   | Ok cats ->
     List.iter cats ~f:(fun c ->
       printf "%s=%s\n" (Category.value c) (Category.name c))
   | Error e -> printf "error: %s\n" e);
  [%expect {|
    dev=Development
    ops=Operations |}]

let%expect_test "parse_category_options_json: name fallback to key" =
  let json = Yojson.Safe.from_string {|{
    "names": {},
    "values": ["dev"]
  }|} in
  (match parse_category_options_json json with
   | Ok cats ->
     List.iter cats ~f:(fun c ->
       printf "%s=%s\n" (Category.value c) (Category.name c))
   | Error e -> printf "error: %s\n" e);
  [%expect {| dev=dev |}]

let%expect_test "parse_category_options_json: empty values" =
  let json = Yojson.Safe.from_string {|{
    "names": {},
    "values": []
  }|} in
  (match parse_category_options_json json with
   | Ok _ -> printf "ok\n"
   | Error e -> printf "error: %s\n" e);
  [%expect {| error: No Tempo category values found |}]
