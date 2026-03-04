open Core

type creds = {
  base_url : string;
  email : string;
  token : string;
}

let auth_header ~creds =
  let encoded = Base64.encode_exn (sprintf "%s:%s" creds.email creds.token) in
  ("Authorization", sprintf "Basic %s" encoded)

let fetch_account_id ~creds =
  let url = sprintf "%s/rest/api/2/myself" creds.base_url in
  let headers = [
    auth_header ~creds;
    ("Accept", "application/json");
  ] in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    let json = Yojson.Safe.from_string response.body in
    match Yojson.Safe.Util.member "accountId" json with
    | `String account_id -> Ok account_id
    | _ -> Error "accountId not found in response"
  else
    Error (sprintf "Jira API error (%d) at %s: %s" response.status url response.body)

(* Extract issue ID and Tempo account ID from a Jira issue response.
   Uses ?expand=names to discover the "Account" custom field. *)
let parse_issue_info_json json =
  let issue_id = match Yojson.Safe.Util.member "id" json with
    | `String id_str -> Int.of_string id_str
    | _ -> failwith "id not found in Jira response"
  in
  let account_key =
    let names = Yojson.Safe.Util.(json |> member "names") in
    let fields = Yojson.Safe.Util.(json |> member "fields") in
    match names with
    | `Assoc name_list ->
      let account_field_id = List.find_map name_list ~f:(fun (field_id, name) ->
        match name with
        | `String n when String.is_substring (String.lowercase n) ~substring:"account" -> Some field_id
        | _ -> None
      ) in
      (match account_field_id with
       | Some field_id ->
         let field_value = Yojson.Safe.Util.member field_id fields in
         (match field_value with
          | `Null -> None
          | `Assoc _ ->
            (match Yojson.Safe.Util.member "id" field_value with
             | `Int id -> Some (Int.to_string id)
             | _ -> None)
          | _ -> None)
       | None -> None)
    | _ -> None
  in
  (issue_id, account_key)

let fetch_issue_info ~creds ~ticket =
  let url = sprintf "%s/rest/api/2/issue/%s?expand=names" creds.base_url ticket in
  let headers = [
    auth_header ~creds;
    ("Accept", "application/json");
  ] in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    let json = Yojson.Safe.from_string response.body in
    Ok (parse_issue_info_json json)
  else
    Error (sprintf "Jira API error (%d): %s" response.status response.body)

let%expect_test "parse_issue_info_json: full response with account" =
  let json = Yojson.Safe.from_string {|{
    "id": "12345",
    "names": {"customfield_10020": "Account"},
    "fields": {"customfield_10020": {"id": 42, "value": "My Account"}}
  }|} in
  let (id, account) = parse_issue_info_json json in
  printf "id=%d account=%s\n" id
    (Option.value account ~default:"none");
  [%expect {| id=12345 account=42 |}]

let%expect_test "parse_issue_info_json: no account field" =
  let json = Yojson.Safe.from_string {|{
    "id": "99",
    "names": {"summary": "Summary"},
    "fields": {"summary": "A ticket"}
  }|} in
  let (id, account) = parse_issue_info_json json in
  printf "id=%d account=%s\n" id
    (Option.value account ~default:"none");
  [%expect {| id=99 account=none |}]

let%expect_test "parse_issue_info_json: account field is null" =
  let json = Yojson.Safe.from_string {|{
    "id": "50",
    "names": {"customfield_10020": "Account"},
    "fields": {"customfield_10020": null}
  }|} in
  let (id, account) = parse_issue_info_json json in
  printf "id=%d account=%s\n" id
    (Option.value account ~default:"none");
  [%expect {| id=50 account=none |}]
