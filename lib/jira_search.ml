open Core

(* === Part A: JQL sanitization === *)

let max_search_length = 200

let sanitize_jql_text input =
  let s = String.strip input in
  if String.is_empty s then None
  else
    let s = if String.length s > max_search_length
      then String.prefix s max_search_length else s in
    let s = String.concat_map s ~f:(function
      | '\\' -> {|\\|}
      | '"' -> {|\"|}
      | '{' | '}' | '[' | ']' | '(' | ')' -> ""
      | c -> String.of_char c)
    in
    let s = String.strip s in
    if String.is_empty s then None else Some s

let validate_project_key = Ticket.is_project_key

let%expect_test "sanitize_jql_text: normal input" =
  let test s = printf "%s\n" (Option.value ~default:"<None>" (sanitize_jql_text s)) in
  test "coding";
  test "auth login";
  test "thingmy-table columns";
  [%expect {|
    coding
    auth login
    thingmy-table columns
    |}]

let%expect_test "sanitize_jql_text: special characters" =
  let test s = printf "%s -> %s\n" s (Option.value ~default:"<None>" (sanitize_jql_text s)) in
  test {|hello "world"|};
  test {|back\slash|};
  test "parens (and) braces {and} brackets [and]";
  test {|nested "quotes \"inside\" here"|};
  [%expect {|
    hello "world" -> hello \"world\"
    back\slash -> back\\slash
    parens (and) braces {and} brackets [and] -> parens and braces and brackets and
    nested "quotes \"inside\" here" -> nested \"quotes \\\"inside\\\" here\"
    |}]

let%expect_test "sanitize_jql_text: edge cases" =
  let test s = printf "%s\n" (Option.value ~default:"<None>" (sanitize_jql_text s)) in
  test "";
  test "   ";
  test "()[]{}";
  test (String.make 300 'a');
  [%expect {|
    <None>
    <None>
    <None>
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    |}]

(* === Part B: JQL query building === *)

let date_minus_days date_str days =
  let date = Date.of_string date_str in
  Date.add_days date (-days) |> Date.to_string

let build_search_jql ~terms ~starred_projects ~log_date =
  match sanitize_jql_text terms with
  | None -> None
  | Some sanitized ->
    let cutoff = date_minus_days log_date 14 in
    let starred = List.filter starred_projects ~f:validate_project_key in
    let scope_clause =
      let parts = ["assignee = currentUser()"; "reporter = currentUser()"] in
      let parts = match starred with
        | [] -> parts
        | keys ->
          let proj_list = String.concat ~sep:", " keys in
          parts @ [sprintf "project in (%s)" proj_list]
      in
      sprintf "(%s)" (String.concat ~sep:" OR " parts)
    in
    Some (sprintf
      {|text ~ "%s" AND (status != Done OR (status = Done AND updated >= "%s")) AND %s ORDER BY updated DESC|}
      sanitized cutoff scope_clause)

let%expect_test "build_search_jql: basic" =
  let test terms starred =
    let jql = build_search_jql ~terms ~starred_projects:starred ~log_date:"2026-02-03" in
    printf "%s\n" (Option.value ~default:"<None>" jql)
  in
  test "coding" [];
  test "auth login" ["DEV"; "ARCH"];
  test "" [];
  [%expect {|
    text ~ "coding" AND (status != Done OR (status = Done AND updated >= "2026-01-20")) AND (assignee = currentUser() OR reporter = currentUser()) ORDER BY updated DESC
    text ~ "auth login" AND (status != Done OR (status = Done AND updated >= "2026-01-20")) AND (assignee = currentUser() OR reporter = currentUser() OR project in (DEV, ARCH)) ORDER BY updated DESC
    <None>
    |}]

let%expect_test "build_search_jql: injection attempts" =
  let test terms =
    let jql = build_search_jql ~terms ~starred_projects:[] ~log_date:"2026-02-03" in
    printf "%s\n" (Option.value ~default:"<None>" jql)
  in
  test {|" OR 1=1 --"|};
  test {|test" AND project = "SECRET|};
  test "normal search";
  [%expect {|
    text ~ "\" OR 1=1 --\"" AND (status != Done OR (status = Done AND updated >= "2026-01-20")) AND (assignee = currentUser() OR reporter = currentUser()) ORDER BY updated DESC
    text ~ "test\" AND project = \"SECRET" AND (status != Done OR (status = Done AND updated >= "2026-01-20")) AND (assignee = currentUser() OR reporter = currentUser()) ORDER BY updated DESC
    text ~ "normal search" AND (status != Done OR (status = Done AND updated >= "2026-01-20")) AND (assignee = currentUser() OR reporter = currentUser()) ORDER BY updated DESC
    |}]

let%expect_test "build_search_jql: invalid starred projects filtered" =
  let jql = build_search_jql ~terms:"test"
    ~starred_projects:["DEV"; "invalid"; "ARCH"; "123"]
    ~log_date:"2026-02-03" in
  printf "%s\n" (Option.value ~default:"<None>" jql);
  [%expect {| text ~ "test" AND (status != Done OR (status = Done AND updated >= "2026-01-20")) AND (assignee = currentUser() OR reporter = currentUser() OR project in (DEV, ARCH)) ORDER BY updated DESC |}]

(* === Part C: Search and lookup API === *)

type search_result = {
  key : string;
  summary : string;
  id : int;
}

let parse_search_results body =
  try
    let json = Yojson.Safe.from_string body in
    let issues = Yojson.Safe.Util.(json |> member "issues" |> to_list) in
    List.filter_map issues ~f:(fun issue ->
      try
        let key = Yojson.Safe.Util.(issue |> member "key" |> to_string) in
        let id = Yojson.Safe.Util.(issue |> member "id" |> to_string |> Int.of_string) in
        let summary = Yojson.Safe.Util.(issue |> member "fields" |> member "summary" |> to_string) in
        Some { key; summary; id }
      with _ -> None)
  with _ -> []

let parse_single_issue body =
  try
    let json = Yojson.Safe.from_string body in
    let key = Yojson.Safe.Util.(json |> member "key" |> to_string) in
    let id = Yojson.Safe.Util.(json |> member "id" |> to_string |> Int.of_string) in
    let summary = Yojson.Safe.Util.(json |> member "fields" |> member "summary" |> to_string) in
    Ok { key; summary; id }
  with exn -> Error (Exn.to_string exn)

let search ~creds ~jql =
  let encoded_jql = Uri.pct_encode jql in
  let url = sprintf "%s/rest/api/3/search/jql?jql=%s&maxResults=5&fields=summary"
    creds.Jira_api.base_url encoded_jql in
  let headers = [Jira_api.auth_header ~creds;
                 ("Accept", "application/json")] in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    Ok (parse_search_results response.body)
  else
    Error (sprintf "Jira search failed (%d): %s" response.status response.body)

let lookup ~creds ~ticket =
  let url = sprintf "%s/rest/api/3/issue/%s?fields=summary"
    creds.Jira_api.base_url (Uri.pct_encode ticket) in
  let headers = [Jira_api.auth_header ~creds;
                 ("Accept", "application/json")] in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    parse_single_issue response.body
  else
    Error (sprintf "not found (%d)" response.status)

let%expect_test "parse_search_results: valid" =
  let body = {|{"issues": [
    {"id": "123", "key": "DEV-1", "fields": {"summary": "First issue"}},
    {"id": "456", "key": "DEV-2", "fields": {"summary": "Second issue"}}
  ]}|} in
  let results = parse_search_results body in
  List.iter results ~f:(fun r -> printf "%s (%d): %s\n" r.key r.id r.summary);
  [%expect {|
    DEV-1 (123): First issue
    DEV-2 (456): Second issue
    |}]

let%expect_test "parse_search_results: empty and malformed" =
  let test body =
    let results = parse_search_results body in
    printf "%d results\n" (List.length results)
  in
  test {|{"issues": []}|};
  test {|{"issues": [{"id": "bad", "key": 123}]}|};
  test {|not json|};
  [%expect {|
    0 results
    0 results
    0 results
    |}]

let%expect_test "parse_single_issue: valid and invalid" =
  let test body =
    match parse_single_issue body with
    | Ok r -> printf "OK: %s (%d) %s\n" r.key r.id r.summary
    | Error e -> printf "Error: %s\n" e
  in
  test {|{"id": "789", "key": "DEV-3", "fields": {"summary": "Third issue"}}|};
  test {|{"bad": "json"}|};
  test {|not json|};
  [%expect {|
    OK: DEV-3 (789) Third issue
    Error: ("Yojson__Safe.Util.Type_error(\"Expected string, got null\", 870828711)")
    Error: ("Yojson__Common.Json_error(\"Line 1, bytes 0-8:\\nInvalid token 'not json'\")")
    |}]

(* Helper to run mocked tests with Output effect handled *)
let run_mocked f =
  Io.Mocked.run @@ fun () ->
    let open Effect.Deep in
    try f () with
    | effect Io.Output s, k ->
        print_string s;
        continue k ()
    | effect (Io.Set_color _), k ->
        continue k ()

let%expect_test "search: success" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    match search ~creds ~jql:{|text ~ "coding"|} with
    | Ok results ->
      List.iter results ~f:(fun r -> Io.output @@ sprintf "%s: %s\n" r.key r.summary)
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 200; body = {|{"issues": [
    {"id": "10", "key": "DEV-1", "fields": {"summary": "Test issue"}}
  ]}|} };
  [%expect {| DEV-1: Test issue |}];
  Io.Mocked.finish t

let%expect_test "search: API error" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    match search ~creds ~jql:{|text ~ "test"|} with
    | Ok _ -> Io.output "unexpected success\n"
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 401; body = "Unauthorized" };
  [%expect {| Error: Jira search failed (401): Unauthorized |}];
  Io.Mocked.finish t

let%expect_test "lookup: success" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    match lookup ~creds ~ticket:"DEV-123" with
    | Ok r -> Io.output @@ sprintf "%s: %s (id=%d)\n" r.key r.summary r.id
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 200;
    body = {|{"id": "999", "key": "DEV-123", "fields": {"summary": "Fix auth"}}|} };
  [%expect {| DEV-123: Fix auth (id=999) |}];
  Io.Mocked.finish t

let%expect_test "lookup: not found" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    match lookup ~creds ~ticket:"BAD-999" with
    | Ok _ -> Io.output "unexpected\n"
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 404; body = "Not Found" };
  [%expect {| Error: not found (404) |}];
  Io.Mocked.finish t

(* === Part D: Prompt loop and cached ticket lookup === *)

type prompt_outcome =
  | Selected of search_result
  | Skip_once
  | Skip_always
  | Split

type lookup_result =
  | Found of search_result
  | Not_found of string

let display_results results =
  List.iteri results ~f:(fun i r ->
    Io.styled @@ sprintf "  %d. {action}%-10s{/} %s\n" (i + 1) r.key r.summary)

let rec prompt_loop ~creds ~search_hint ~has_tags ~starred_projects ~log_date =
  let tag_opt = if has_tags then " | [s] split" else "" in
  let action = if Ticket.is_ticket_pattern search_hint then "look up" else "search" in
  Io.styled @@ sprintf "  {prompt}[Enter] %s \"%s\" | [ticket/search]%s | [n] skip | [S] skip always:{/} "
    action search_hint tag_opt;
  let input = Io.input () in
  match input with
  | "n" -> Skip_once
  | "S" -> Skip_always
  | "s" when has_tags -> Split
  | "" when Ticket.is_ticket_pattern search_hint ->
    (match handle_ticket_input ~creds ~starred_projects ~log_date search_hint with
     | Some r -> Selected r
     | None -> prompt_loop ~creds ~search_hint ~has_tags ~starred_projects ~log_date)
  | "" ->
    (match search_and_display ~creds ~starred_projects ~log_date search_hint with
     | Some r -> Selected r
     | None -> Skip_once)
  | s when Ticket.is_ticket_pattern s ->
    (match handle_ticket_input ~creds ~starred_projects ~log_date s with
     | Some r -> Selected r
     | None -> prompt_loop ~creds ~search_hint ~has_tags ~starred_projects ~log_date)
  | s ->
    (match search_and_display ~creds ~starred_projects ~log_date s with
     | Some r -> Selected r
     | None -> prompt_loop ~creds ~search_hint ~has_tags ~starred_projects ~log_date)

and results_loop ~creds ~starred_projects ~log_date ~results =
  Io.styled "  {prompt}[#] select | [text] search again | [n] back:{/} ";
  let input = Io.input () in
  match input with
  | "n" -> None
  | s when Ticket.is_ticket_pattern s -> handle_ticket_input ~creds ~starred_projects ~log_date s
  | s ->
    (match Int.of_string_opt s with
     | Some n when n >= 1 && n <= List.length results ->
       Some (List.nth_exn results (n - 1))
     | _ -> search_and_display ~creds ~starred_projects ~log_date s)

and handle_ticket_input ~creds ~starred_projects ~log_date ticket =
  Io.styled @@ sprintf "  {dim}Looking up %s...{/} " ticket;
  match lookup ~creds ~ticket with
  | Ok result ->
    Io.styled @@ sprintf "\n  {action}%s{/}  %s\n" result.key result.summary;
    Io.styled "  {prompt}[Enter] confirm | [text] search again | [n] back:{/} ";
    (match Io.input () with
     | "" -> Some result
     | "n" -> None
     | s -> search_and_display ~creds ~starred_projects ~log_date s)
  | Error msg ->
    Io.styled @@ sprintf "{err}%s{/}\n" msg;
    Io.styled "  {prompt}[text] try again | [n] back:{/} ";
    (match Io.input () with
     | "n" -> None
     | s when Ticket.is_ticket_pattern s ->
       handle_ticket_input ~creds ~starred_projects ~log_date s
     | s -> search_and_display ~creds ~starred_projects ~log_date s)

and search_and_display ~creds ~starred_projects ~log_date terms =
  match build_search_jql ~terms ~starred_projects ~log_date with
  | None ->
    Io.styled "  {warn}No search terms provided.{/}\n";
    None
  | Some jql ->
    begin match search ~creds ~jql with
    | Ok [] ->
      Io.styled "  {dim}No results found.{/}\n";
      Io.styled "  {prompt}[text] search again | [n] back:{/} ";
      (match Io.input () with
       | "n" -> None
       | s -> search_and_display ~creds ~starred_projects ~log_date s)
    | Ok results ->
      display_results results;
      results_loop ~creds ~starred_projects ~log_date ~results
    | Error msg ->
      Io.styled @@ sprintf "  {err}Search failed: %s{/}\n" msg;
      None
    end

let lookup_cached_ticket ~creds ~ticket =
  Io.styled @@ sprintf "  {dim}Looking up %s...{/} " ticket;
  match lookup ~creds ~ticket with
  | Ok result ->
    Io.styled "{ok}OK{/}\n";
    Found result
  | Error msg ->
    Io.styled @@ sprintf "{err}%s{/}\n" msg;
    Not_found msg

(* === Mocked IO tests for prompt loop === *)

let%expect_test "prompt_loop: search and select" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"coding"
      ~has_tags:false ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Selected r -> Io.output @@ sprintf "Selected: %s\n" r.key
    | Skip_once -> Io.output "Skip_once\n"
    | Skip_always -> Io.output "Skip_always\n"
    | Split -> Io.output "Split\n")
  in
  [%expect {| [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "";
  [%expect {||}];
  Io.Mocked.http_get t { Io.status = 200; body = {|{"issues": [
    {"id": "10", "key": "CODE-42", "fields": {"summary": "Refactor auth"}}
  ]}|} };
  [%expect {|
    1. CODE-42    Refactor auth
    [#] select | [text] search again | [n] back:
    |}];
  Io.Mocked.input t "1";
  [%expect {| Selected: CODE-42 |}];
  Io.Mocked.finish t

let%expect_test "prompt_loop: direct ticket input" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"coding"
      ~has_tags:false ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Selected r -> Io.output @@ sprintf "Selected: %s\n" r.key
    | Skip_once -> Io.output "Skip_once\n"
    | _ -> Io.output "other\n")
  in
  [%expect {| [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "DEV-123";
  [%expect {| Looking up DEV-123... |}];
  Io.Mocked.http_get t { Io.status = 200;
    body = {|{"id": "999", "key": "DEV-123", "fields": {"summary": "Fix auth"}}|} };
  [%expect {|
    DEV-123  Fix auth
    [Enter] confirm | [text] search again | [n] back:
    |}];
  Io.Mocked.input t "";
  [%expect {| Selected: DEV-123 |}];
  Io.Mocked.finish t

let%expect_test "prompt_loop: ticket lookup fails then back" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"coding"
      ~has_tags:false ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Selected r -> Io.output @@ sprintf "Selected: %s\n" r.key
    | Skip_once -> Io.output "Skip_once\n"
    | _ -> Io.output "other\n")
  in
  [%expect {| [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "BAD-999";
  [%expect {| Looking up BAD-999... |}];
  Io.Mocked.http_get t { Io.status = 404; body = "Not Found" };
  [%expect {|
    not found (404)
      [text] try again | [n] back:
    |}];
  Io.Mocked.input t "n";
  [%expect {| [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "n";
  [%expect {| Skip_once |}];
  Io.Mocked.finish t

let%expect_test "prompt_loop: skip once" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"coding"
      ~has_tags:false ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Skip_once -> Io.output "Skip_once\n"
    | _ -> Io.output "other\n")
  in
  [%expect {| [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "n";
  [%expect {| Skip_once |}];
  Io.Mocked.finish t

let%expect_test "prompt_loop: skip always" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"coding"
      ~has_tags:false ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Skip_always -> Io.output "Skip_always\n"
    | _ -> Io.output "other\n")
  in
  [%expect {| [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "S";
  [%expect {| Skip_always |}];
  Io.Mocked.finish t

let%expect_test "prompt_loop: split" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"coding"
      ~has_tags:true ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Split -> Io.output "Split\n"
    | _ -> Io.output "other\n")
  in
  [%expect {| [Enter] search "coding" | [ticket/search] | [s] split | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "s";
  [%expect {| Split |}];
  Io.Mocked.finish t

let%expect_test "prompt_loop: no results" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"nonexistent"
      ~has_tags:false ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Skip_once -> Io.output "Skip_once\n"
    | _ -> Io.output "other\n")
  in
  [%expect {| [Enter] search "nonexistent" | [ticket/search] | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "";
  [%expect {||}];
  Io.Mocked.http_get t { Io.status = 200; body = {|{"issues": []}|} };
  [%expect {|
    No results found.
    [text] search again | [n] back:
    |}];
  Io.Mocked.input t "n";
  [%expect {| Skip_once |}];
  Io.Mocked.finish t

let%expect_test "prompt_loop: search twice then select from second results" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"coding"
      ~has_tags:false ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Selected r -> Io.output @@ sprintf "Selected: %s\n" r.key
    | Skip_once -> Io.output "Skip_once\n"
    | Skip_always -> Io.output "Skip_always\n"
    | Split -> Io.output "Split\n")
  in
  [%expect {| [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "auth";
  [%expect {||}];
  Io.Mocked.http_get t { Io.status = 200; body = {|{"issues": [
    {"id": "10", "key": "AUTH-1", "fields": {"summary": "Auth service"}},
    {"id": "11", "key": "AUTH-2", "fields": {"summary": "Auth middleware"}}
  ]}|} };
  [%expect {|
    1. AUTH-1     Auth service
    2. AUTH-2     Auth middleware
    [#] select | [text] search again | [n] back:
    |}];
  Io.Mocked.input t "login";
  [%expect {||}];
  Io.Mocked.http_get t { Io.status = 200; body = {|{"issues": [
    {"id": "20", "key": "LOG-1", "fields": {"summary": "Login flow"}},
    {"id": "21", "key": "LOG-2", "fields": {"summary": "Login page"}}
  ]}|} };
  [%expect {|
    1. LOG-1      Login flow
    2. LOG-2      Login page
    [#] select | [text] search again | [n] back:
    |}];
  Io.Mocked.input t "1";
  [%expect {| Selected: LOG-1 |}];
  Io.Mocked.finish t

let%expect_test "prompt_loop: ticket pattern input from results list" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"coding"
      ~has_tags:false ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Selected r -> Io.output @@ sprintf "Selected: %s\n" r.key
    | _ -> Io.output "other\n")
  in
  [%expect {| [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "";
  [%expect {||}];
  Io.Mocked.http_get t { Io.status = 200; body = {|{"issues": [
    {"id": "10", "key": "CODE-1", "fields": {"summary": "Some code thing"}}
  ]}|} };
  [%expect {|
    1. CODE-1     Some code thing
    [#] select | [text] search again | [n] back:
    |}];
  (* User types a ticket key instead of selecting a number *)
  Io.Mocked.input t "DEV-50";
  [%expect {| Looking up DEV-50... |}];
  Io.Mocked.http_get t { Io.status = 200;
    body = {|{"id": "50", "key": "DEV-50", "fields": {"summary": "Direct lookup"}}|} };
  [%expect {|
    DEV-50  Direct lookup
    [Enter] confirm | [text] search again | [n] back:
    |}];
  Io.Mocked.input t "";
  [%expect {| Selected: DEV-50 |}];
  Io.Mocked.finish t

let%expect_test "prompt_loop: ticket pattern hint does lookup not search" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"DEV-42"
      ~has_tags:false ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Selected r -> Io.output @@ sprintf "Selected: %s\n" r.key
    | _ -> Io.output "other\n")
  in
  [%expect {| [Enter] look up "DEV-42" | [ticket/search] | [n] skip | [S] skip always: |}];
  Io.Mocked.input t "";
  [%expect {| Looking up DEV-42... |}];
  Io.Mocked.http_get t { Io.status = 200;
    body = {|{"id": "42", "key": "DEV-42", "fields": {"summary": "Some feature"}}|} };
  [%expect {|
    DEV-42  Some feature
    [Enter] confirm | [text] search again | [n] back:
    |}];
  Io.Mocked.input t "";
  [%expect {| Selected: DEV-42 |}];
  Io.Mocked.finish t

let%expect_test "lookup_cached_ticket: success" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    match lookup_cached_ticket ~creds ~ticket:"DEV-42" with
    | Found r -> Io.output @@ sprintf "Found: %s - %s\n" r.key r.summary
    | Not_found msg -> Io.output @@ sprintf "Not found: %s\n" msg)
  in
  Io.Mocked.http_get t { Io.status = 200;
    body = {|{"id": "42", "key": "DEV-42", "fields": {"summary": "Some feature"}}|} };
  [%expect {|
      Looking up DEV-42... OK
    Found: DEV-42 - Some feature
    |}];
  Io.Mocked.finish t

let%expect_test "lookup_cached_ticket: failure" =
  let creds = { Jira_api.base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = run_mocked (fun () ->
    match lookup_cached_ticket ~creds ~ticket:"BAD-1" with
    | Found _ -> Io.output "unexpected\n"
    | Not_found msg -> Io.output @@ sprintf "Not found: %s\n" msg)
  in
  Io.Mocked.http_get t { Io.status = 404; body = "Not Found" };
  [%expect {|
      Looking up BAD-1... not found (404)
    Not found: not found (404)
    |}];
  Io.Mocked.finish t
