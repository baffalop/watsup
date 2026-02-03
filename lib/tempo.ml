open Core
open Lwt.Syntax
open Cohttp_lwt_unix

type category = {
  id : int;
  name : string;
}
[@@deriving sexp]

type account = {
  id : int;
  name : string;
}
[@@deriving sexp]

let base_url = "https://api.tempo.io/4"

let headers token =
  Cohttp.Header.of_list
    [
      ("Authorization", sprintf "Bearer %s" token);
      ("Content-Type", "application/json");
    ]

let fetch_categories ~token : category list Or_error.t Lwt.t =
  let uri = Uri.of_string (base_url ^ "/work-attributes") in
  let* resp, body = Client.get ~headers:(headers token) uri in
  let* body_str = Cohttp_lwt.Body.to_string body in
  let status = Cohttp.Response.status resp in
  if Cohttp.Code.is_success (Cohttp.Code.code_of_status status) then
    try
      let json = Yojson.Safe.from_string body_str in
      let results =
        Yojson.Safe.Util.(json |> member "results" |> to_list)
      in
      let categories : category list =
        List.filter_map results ~f:(fun item ->
            let open Yojson.Safe.Util in
            try
              let id = item |> member "id" |> to_int in
              let name = item |> member "name" |> to_string in
              Some ({ id; name } : category)
            with
            | _ -> None)
      in
      Lwt.return (Ok categories)
    with
    | exn -> Lwt.return (Or_error.error_string (Exn.to_string exn))
  else Lwt.return (Or_error.error_string (sprintf "API error: %s" body_str))

let fetch_account_for_ticket ~token ~ticket =
  let uri =
    Uri.of_string (sprintf "%s/accounts/search?issueKey=%s" base_url ticket)
  in
  let* resp, body = Client.get ~headers:(headers token) uri in
  let* body_str = Cohttp_lwt.Body.to_string body in
  let status = Cohttp.Response.status resp in
  if Cohttp.Code.is_success (Cohttp.Code.code_of_status status) then
    try
      let json = Yojson.Safe.from_string body_str in
      let results =
        Yojson.Safe.Util.(json |> member "results" |> to_list)
      in
      match results with
      | [] -> Lwt.return (Ok None)
      | item :: _ ->
        let open Yojson.Safe.Util in
        let id = item |> member "id" |> to_int in
        let name = item |> member "name" |> to_string in
        Lwt.return (Ok (Some { id; name }))
    with
    | exn -> Lwt.return (Or_error.error_string (Exn.to_string exn))
  else Lwt.return (Or_error.error_string (sprintf "API error: %s" body_str))

let post_worklog ~token worklog =
  let uri = Uri.of_string (base_url ^ "/worklogs") in
  let body_json =
    `Assoc
      [
        ("issueKey", `String worklog.Worklog.ticket);
        ("timeSpentSeconds", `Int (Duration.to_seconds worklog.duration));
        ("startDate", `String (Date.to_string worklog.date));
        ("startTime", `String "09:00:00");
        ( "description",
          `String (Option.value worklog.message ~default:"") );
        ("authorAccountId", `String "self");
      ]
  in
  let body = Cohttp_lwt.Body.of_string (Yojson.Safe.to_string body_json) in
  let* resp, resp_body = Client.post ~headers:(headers token) ~body uri in
  let* body_str = Cohttp_lwt.Body.to_string resp_body in
  let status = Cohttp.Response.status resp in
  if Cohttp.Code.is_success (Cohttp.Code.code_of_status status) then
    Lwt.return Worklog.Posted
  else if Cohttp.Code.code_of_status status = 401 then
    Lwt.return (Worklog.Failed "Unauthorized - check your API token")
  else Lwt.return (Worklog.Failed body_str)
