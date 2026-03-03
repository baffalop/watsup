# Jira Ticket Search & Completion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
>
> **Sub-agent instructions:** Do NOT use command substitution (`$(cat <<'EOF' ... EOF)`) in git commit commands. Use simple single-quoted strings instead.

**Goal:** Add inline Jira ticket search to ticket assignment prompts, with scoped JQL queries, input sanitization, and cached ticket title display.

**Architecture:** New `Jira_search` module owns all search/lookup/prompt logic, tested in isolation. Config gets a `starred_projects` field. Main_logic delegates to Jira_search for ticket assignment. Temporary `--search` CLI flag enables manual testing in isolation.

**Tech Stack:** OCaml 5.4, Effect handlers (Io module), Jira REST API v2 (`/rest/api/2/search`, `/rest/api/2/issue/{key}`), Re (regex), Yojson (JSON), Climate (CLI)

**Design doc:** `docs/plans/2026-03-03-jira-search-design.md`

---

### Task 1: Config — add `starred_projects` field

**Files:**
- Modify: `lib/config.ml:21-34` (add field to type t)
- Modify: `lib/config.mli` (expose field if mli exposes type)

**Step 1: Add field to Config.t**

In `lib/config.ml`, add to the `type t` record after `category_selections`:

```ocaml
  starred_projects : string list [@default []];
```

**Step 2: Update Config.empty**

In `lib/config.ml`, add to the `empty` value:

```ocaml
  starred_projects = [];
```

**Step 3: Run tests to verify backwards compatibility**

Run: `opam exec -- dune runtest`
Expected: All existing tests pass (the `[@default []]` means old configs load fine).

**Step 4: Commit**

```
git add lib/config.ml lib/config.mli
git commit -m 'feat: add starred_projects field to Config.t'
```

---

### Task 2: CLI — add `--star-projects` command

**Files:**
- Modify: `bin/main.ml`
- Modify: `lib/ticket.ml` (expose project key validation)

**Step 1: Add project key validation to Ticket module**

In `lib/ticket.ml`, add:

```ocaml
let project_key_re = Re.Pcre.regexp {|^[A-Z][A-Z0-9_]+$|}

let is_project_key s = Re.execp project_key_re s
```

Expose in `lib/ticket.mli`:

```ocaml
val is_project_key : string -> bool
```

**Step 2: Write inline test for project key validation**

In `lib/ticket.ml`:

```ocaml
let%expect_test "is_project_key" =
  let test s = printf "%s: %b\n" s (is_project_key s) in
  test "DEV";
  test "LOG";
  test "MY_PROJECT";
  test "A2B";
  test "dev";
  test "DEV-123";
  test "D";
  test "";
  test "123";
  [%expect {||}]
```

**Step 3: Run test, review output, promote**

Run: `opam exec -- dune runtest`
Review diff, then: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 4: Add `--star-projects` CLI flag to `bin/main.ml`**

Add a new `named_opt` for star_projects alongside existing args. When provided, parse the comma-separated list, validate each key with `Ticket.is_project_key`, update config, save, and exit.

```ocaml
and+ star_projects = named_opt ~doc:"Comma-separated project keys to star" ["star-projects"] string
```

In the main body, before date resolution, handle:

```ocaml
match star_projects with
| Some keys_str ->
  let keys = String.split keys_str ~on:',' |> List.map ~f:String.strip in
  let invalid = List.filter keys ~f:(fun k -> not (Ticket.is_project_key k)) in
  if not (List.is_empty invalid) then
    failwith (sprintf "Invalid project keys: %s" (String.concat ~sep:", " invalid));
  let config = Config.load ~path:config_path |> Or_error.ok_exn in
  let config = { config with starred_projects = keys } in
  Config.save ~path:config_path config |> Or_error.ok_exn;
  printf "Starred projects: %s\n" (String.concat ~sep:", " keys)
| None ->
  (* existing date resolution + run logic *)
```

**Step 5: Run tests**

Run: `opam exec -- dune runtest`
Expected: All tests pass.

**Step 6: Commit**

```
git add lib/ticket.ml lib/ticket.mli bin/main.ml
git commit -m 'feat: add --star-projects CLI command'
```

---

### Task 3: Jira_search — JQL sanitization (pure functions, unit tested)

**Files:**
- Create: `lib/jira_search.ml`
- Create: `lib/jira_search.mli`

**Step 1: Create module with sanitization function and empty expect tests**

Create `lib/jira_search.ml`:

```ocaml
open Core

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
  [%expect {||}]

let%expect_test "sanitize_jql_text: special characters" =
  let test s = printf "%s -> %s\n" s (Option.value ~default:"<None>" (sanitize_jql_text s)) in
  test {|hello "world"|};
  test {|back\slash|};
  test "parens (and) braces {and} brackets [and]";
  test {|nested "quotes \"inside\" here"|};
  [%expect {||}]

let%expect_test "sanitize_jql_text: edge cases" =
  let test s = printf "%s\n" (Option.value ~default:"<None>" (sanitize_jql_text s)) in
  test "";
  test "   ";
  test "()[]{}";
  test (String.make 300 'a');
  [%expect {||}]
```

Create `lib/jira_search.mli`:

```ocaml
val sanitize_jql_text : string -> string option
val validate_project_key : string -> bool
```

**Step 2: Run tests, review output, promote**

Run: `opam exec -- dune runtest`
Review the diff carefully — ensure sanitization is correct.
Then: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 3: Commit**

```
git add lib/jira_search.ml lib/jira_search.mli
git commit -m 'feat: add Jira_search module with JQL sanitization'
```

---

### Task 4: Jira_search — JQL query building (pure functions, unit tested)

**Files:**
- Modify: `lib/jira_search.ml`
- Modify: `lib/jira_search.mli`

**Step 1: Add `build_search_jql` function**

In `lib/jira_search.ml`, add:

```ocaml
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
```

Expose in `lib/jira_search.mli`:

```ocaml
val build_search_jql :
  terms:string ->
  starred_projects:string list ->
  log_date:string ->
  string option
```

**Step 2: Write expect tests**

```ocaml
let%expect_test "build_search_jql: basic" =
  let test terms starred =
    let jql = build_search_jql ~terms ~starred_projects:starred ~log_date:"2026-02-03" in
    printf "%s\n" (Option.value ~default:"<None>" jql)
  in
  test "coding" [];
  test "auth login" ["DEV"; "ARCH"];
  test "" [];
  [%expect {||}]

let%expect_test "build_search_jql: injection attempts" =
  let test terms =
    let jql = build_search_jql ~terms ~starred_projects:[] ~log_date:"2026-02-03" in
    printf "%s\n" (Option.value ~default:"<None>" jql)
  in
  test {|" OR 1=1 --"|};
  test {|test" AND project = "SECRET|};
  test "normal search";
  [%expect {||}]

let%expect_test "build_search_jql: invalid starred projects filtered" =
  let jql = build_search_jql ~terms:"test"
    ~starred_projects:["DEV"; "invalid"; "ARCH"; "123"]
    ~log_date:"2026-02-03" in
  printf "%s\n" (Option.value ~default:"<None>" jql);
  [%expect {||}]
```

**Step 3: Run tests, review, promote**

Run: `opam exec -- dune runtest`
Review: ensure injection attempts are properly escaped, starred project filtering works.
Then: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 4: Commit**

```
git add lib/jira_search.ml lib/jira_search.mli
git commit -m 'feat: add JQL query building with scoping and injection prevention'
```

---

### Task 5: Jira_search — search and lookup API functions

**Files:**
- Modify: `lib/jira_search.ml`
- Modify: `lib/jira_search.mli`

**Step 1: Add types and API functions**

In `lib/jira_search.ml`, add:

```ocaml
type search_result = {
  key : string;
  summary : string;
  id : int;
}

let jira_auth_header ~email ~token =
  let encoded = Base64.encode_exn (sprintf "%s:%s" email token) in
  ("Authorization", sprintf "Basic %s" encoded)

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

let search ~jira_base_url ~email ~token ~jql =
  let encoded_jql = Uri.pct_encode jql in
  let url = sprintf "%s/rest/api/2/search?jql=%s&maxResults=5&fields=summary"
    jira_base_url encoded_jql in
  let headers = [jira_auth_header ~email ~token; ("Accept", "application/json")] in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    Ok (parse_search_results response.body)
  else
    Error (sprintf "Jira search failed (%d): %s" response.status response.body)

let lookup ~jira_base_url ~email ~token ~ticket =
  let url = sprintf "%s/rest/api/2/issue/%s?fields=summary"
    jira_base_url (Uri.pct_encode ticket) in
  let headers = [jira_auth_header ~email ~token; ("Accept", "application/json")] in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    parse_single_issue response.body
  else
    Error (sprintf "not found (%d)" response.status)
```

Expose in `lib/jira_search.mli`:

```ocaml
type search_result = { key : string; summary : string; id : int }

val parse_search_results : string -> search_result list
val parse_single_issue : string -> (search_result, string) result

val search :
  jira_base_url:string -> email:string -> token:string -> jql:string ->
  (search_result list, string) result

val lookup :
  jira_base_url:string -> email:string -> token:string -> ticket:string ->
  (search_result, string) result
```

**Step 2: Write unit tests for JSON parsing (pure)**

```ocaml
let%expect_test "parse_search_results: valid" =
  let body = {|{"issues": [
    {"id": "123", "key": "DEV-1", "fields": {"summary": "First issue"}},
    {"id": "456", "key": "DEV-2", "fields": {"summary": "Second issue"}}
  ]}|} in
  let results = parse_search_results body in
  List.iter results ~f:(fun r -> printf "%s (%d): %s\n" r.key r.id r.summary);
  [%expect {||}]

let%expect_test "parse_search_results: empty and malformed" =
  let test body =
    let results = parse_search_results body in
    printf "%d results\n" (List.length results)
  in
  test {|{"issues": []}|};
  test {|{"issues": [{"id": "bad", "key": 123}]}|};
  test {|not json|};
  [%expect {||}]

let%expect_test "parse_single_issue: valid and invalid" =
  let test body =
    match parse_single_issue body with
    | Ok r -> printf "OK: %s (%d) %s\n" r.key r.id r.summary
    | Error e -> printf "Error: %s\n" e
  in
  test {|{"id": "789", "key": "DEV-3", "fields": {"summary": "Third issue"}}|};
  test {|{"bad": "json"}|};
  test {|not json|};
  [%expect {||}]
```

**Step 3: Write mocked IO tests for search and lookup**

```ocaml
let%expect_test "search: success" =
  let t = Io.Mocked.run (fun () ->
    match search ~jira_base_url:"https://test.atlassian.net"
      ~email:"user@test.com" ~token:"tok" ~jql:"text ~ \"coding\"" with
    | Ok results ->
      List.iter results ~f:(fun r -> Io.output @@ sprintf "%s: %s\n" r.key r.summary)
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 200; body = {|{"issues": [
    {"id": "10", "key": "DEV-1", "fields": {"summary": "Test issue"}}
  ]}|} };
  [%expect {||}];
  Io.Mocked.finish t

let%expect_test "search: API error" =
  let t = Io.Mocked.run (fun () ->
    match search ~jira_base_url:"https://test.atlassian.net"
      ~email:"user@test.com" ~token:"tok" ~jql:"text ~ \"test\"" with
    | Ok _ -> Io.output "unexpected success\n"
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 401; body = "Unauthorized" };
  [%expect {||}];
  Io.Mocked.finish t

let%expect_test "lookup: success" =
  let t = Io.Mocked.run (fun () ->
    match lookup ~jira_base_url:"https://test.atlassian.net"
      ~email:"user@test.com" ~token:"tok" ~ticket:"DEV-123" with
    | Ok r -> Io.output @@ sprintf "%s: %s (id=%d)\n" r.key r.summary r.id
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 200;
    body = {|{"id": "999", "key": "DEV-123", "fields": {"summary": "Fix auth"}}|} };
  [%expect {||}];
  Io.Mocked.finish t

let%expect_test "lookup: not found" =
  let t = Io.Mocked.run (fun () ->
    match lookup ~jira_base_url:"https://test.atlassian.net"
      ~email:"user@test.com" ~token:"tok" ~ticket:"BAD-999" with
    | Ok _ -> Io.output "unexpected\n"
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 404; body = "Not Found" };
  [%expect {||}];
  Io.Mocked.finish t
```

**Step 4: Run tests, review, promote**

Run: `opam exec -- dune runtest`
Review, then: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 5: Commit**

```
git add lib/jira_search.ml lib/jira_search.mli
git commit -m 'feat: add Jira search and lookup API functions'
```

---

### Task 6: Jira_search — prompt loop (mocked IO tests)

**Files:**
- Modify: `lib/jira_search.ml`
- Modify: `lib/jira_search.mli`

This is the core interactive loop. It needs a `jira_creds` record to avoid threading many parameters.

**Step 1: Add credential record and prompt_loop function**

```ocaml
type jira_creds = {
  base_url : string;
  email : string;
  token : string;
}

type prompt_outcome =
  | Selected of search_result
  | Skip_once
  | Skip_always
  | Split

let display_results results =
  List.iteri results ~f:(fun i r ->
    Io.output @@ sprintf "  %d. %-10s %s\n" (i + 1) r.key r.summary)

let rec results_loop ~creds ~results =
  Io.output "  [#] select | [text] search again | [n] back: ";
  let input = Io.input () in
  match input with
  | "n" -> None
  | s when Ticket.is_ticket_pattern s -> handle_ticket_input ~creds s
  | s ->
    (match Int.of_string_opt s with
     | Some n when n >= 1 && n <= List.length results ->
       Some (List.nth_exn results (n - 1))
     | _ -> search_and_display ~creds s)

and handle_ticket_input ~creds ticket =
  Io.output @@ sprintf "  Looking up %s... " ticket;
  match lookup ~jira_base_url:creds.base_url ~email:creds.email ~token:creds.token ~ticket with
  | Ok result ->
    Io.output @@ sprintf "\n  %s  %s\n" result.key result.summary;
    Io.output "  [Enter] confirm | [text] search again | [n] back: ";
    (match Io.input () with
     | "" -> Some result
     | "n" -> None
     | s -> search_and_display ~creds s)
  | Error msg ->
    Io.output @@ sprintf "%s\n" msg;
    Io.output "  [text] try again | [n] back: ";
    (match Io.input () with
     | "n" -> None
     | s when Ticket.is_ticket_pattern s -> handle_ticket_input ~creds s
     | s -> search_and_display ~creds s)

and search_and_display ~creds terms =
  match build_search_jql ~terms ~starred_projects:[] ~log_date:"2026-01-01" with
  | None ->
    Io.output "  No search terms provided.\n";
    None
  | Some jql ->
    match search ~jira_base_url:creds.base_url ~email:creds.email ~token:creds.token ~jql with
    | Ok [] ->
      Io.output "  No results found.\n";
      Io.output "  [text] search again | [n] back: ";
      (match Io.input () with
       | "n" -> None
       | s -> search_and_display ~creds s)
    | Ok results ->
      display_results results;
      results_loop ~creds ~results
    | Error msg ->
      Io.output @@ sprintf "  Search failed: %s\n" msg;
      None

(* Main entry point — called from prompt_uncached_entry *)
let prompt_loop ~creds ~search_hint ~has_tags ~starred_projects ~log_date =
  let tag_opt = if has_tags then " | [s] split" else "" in
  Io.output @@ sprintf "  [Enter] search \"%s\" | [ticket/search]%s | [n] skip | [S] skip always: "
    search_hint tag_opt;
  let input = Io.input () in
  match input with
  | "n" -> Skip_once
  | "S" -> Skip_always
  | "s" when has_tags -> Split
  | "" ->
    let result = search_and_display_full ~creds ~terms:search_hint
      ~starred_projects ~log_date in
    (match result with Some r -> Selected r | None -> Skip_once)
  | s when Ticket.is_ticket_pattern s ->
    (match handle_ticket_input ~creds s with
     | Some r -> Selected r
     | None -> prompt_loop ~creds ~search_hint ~has_tags ~starred_projects ~log_date)
  | s ->
    let result = search_and_display_full ~creds ~terms:s
      ~starred_projects ~log_date in
    (match result with
     | Some r -> Selected r
     | None -> prompt_loop ~creds ~search_hint ~has_tags ~starred_projects ~log_date)
```

Note: `search_and_display_full` is like `search_and_display` but uses the full `build_search_jql` with starred_projects and log_date. The `search_and_display` inside the results loop should also use these parameters — thread them through. The exact implementation will need adjusting during development; the above is a guide.

**Step 2: Write mocked IO tests for the prompt loop**

Write tests covering:
1. User hits Enter, search returns results, user selects #1
2. User types a ticket key directly, lookup succeeds, user confirms
3. User types a ticket key, lookup fails, user types `n` to go back
4. User types search terms, gets results, searches again, then selects
5. User types `n` to skip, `S` to skip always, `s` to split
6. Empty search results — user gets "no results" message

Each test follows the pattern from `test_e2e.ml`:
```ocaml
let%expect_test "prompt_loop: search and select" =
  let creds = { base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = Io.Mocked.run (fun () ->
    let outcome = prompt_loop ~creds ~search_hint:"coding"
      ~has_tags:false ~starred_projects:[] ~log_date:"2026-02-03" in
    match outcome with
    | Selected r -> Io.output @@ sprintf "Selected: %s\n" r.key
    | Skip_once -> Io.output "Skip_once\n"
    | Skip_always -> Io.output "Skip_always\n"
    | Split -> Io.output "Split\n")
  in
  (* Prompt shown *)
  [%expect {||}];
  (* User hits Enter to search *)
  Io.Mocked.input t "";
  (* HTTP search request *)
  [%expect {||}];
  Io.Mocked.http_get t { Io.status = 200; body = {|{"issues": [
    {"id": "10", "key": "CODE-42", "fields": {"summary": "Refactor auth"}}
  ]}|} };
  (* Results shown, user selects 1 *)
  [%expect {||}];
  Io.Mocked.input t "1";
  [%expect {||}];
  Io.Mocked.finish t
```

Write similar tests for the other scenarios listed above.

**Step 3: Run tests, review, promote**

Run: `opam exec -- dune runtest`
Review, then: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 4: Commit**

```
git add lib/jira_search.ml lib/jira_search.mli
git commit -m 'feat: add interactive search prompt loop'
```

---

### Task 7: CLI — temporary `--search` flag + MANUAL TESTING CHECKPOINT

**Files:**
- Modify: `bin/main.ml`

**Step 1: Add `--search` flag to CLI**

Add a new Climate arg:

```ocaml
and+ search_mode = named_opt ~doc:"Test search prompt in isolation" ["search"] string
```

When `search_mode` is `Some search_terms`:
1. Load config
2. Verify Jira credentials are present (fail with helpful message if not)
3. Build `Jira_search.jira_creds` from config
4. Call `Jira_search.prompt_loop` with the search terms as hint
5. Print the outcome and exit

This runs inside `Io.with_stdio` so it uses real HTTP and real stdin/stdout.

**Step 2: Run tests**

Run: `opam exec -- dune runtest`
Expected: All tests pass.

**Step 3: Commit**

```
git add bin/main.ml
git commit -m 'feat: add temporary --search flag for manual testing'
```

**Step 4: MANUAL TESTING CHECKPOINT**

> **STOP HERE.** Ask the user to manually test:
>
> ```bash
> # Ensure credentials are configured
> ./scripts/test-cli.sh restore
>
> # Test search with a keyword
> opam exec -- dune exec watsup -- --search "coding"
>
> # Test search with starred projects (if configured)
> opam exec -- dune exec watsup -- --star-projects DEV,LOG
> opam exec -- dune exec watsup -- --search "refactor"
> ```
>
> Verify:
> 1. JQL query reaches Jira and returns results
> 2. Results display correctly with key + summary
> 3. Selecting a result by number works
> 4. Typing a ticket key does a direct lookup
> 5. Error cases (bad credentials, no results) show helpful messages
>
> Report any issues before proceeding to integration.

---

### Task 8: Jira_search — cached ticket lookup function

**Files:**
- Modify: `lib/jira_search.ml`
- Modify: `lib/jira_search.mli`

**Step 1: Add `lookup_cached_ticket` function**

This is what `main_logic.ml` calls before showing the cached entry prompt:

```ocaml
type lookup_result =
  | Found of search_result
  | Not_found of string  (* error message *)

let lookup_cached_ticket ~creds ~ticket =
  Io.output @@ sprintf "  Looking up %s... " ticket;
  match lookup ~jira_base_url:creds.base_url ~email:creds.email ~token:creds.token ~ticket with
  | Ok result ->
    Io.output "OK\n";
    Found result
  | Error msg ->
    Io.output @@ sprintf "%s\n" msg;
    Not_found msg
```

Expose in mli:

```ocaml
type lookup_result = Found of search_result | Not_found of string
val lookup_cached_ticket : creds:jira_creds -> ticket:string -> lookup_result
```

**Step 2: Write mocked IO tests**

```ocaml
let%expect_test "lookup_cached_ticket: success" =
  let creds = { base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = Io.Mocked.run (fun () ->
    match lookup_cached_ticket ~creds ~ticket:"DEV-123" with
    | Found r -> Io.output @@ sprintf "Found: %s %s\n" r.key r.summary
    | Not_found msg -> Io.output @@ sprintf "Not found: %s\n" msg)
  in
  [%expect {||}];
  Io.Mocked.http_get t { Io.status = 200;
    body = {|{"id": "999", "key": "DEV-123", "fields": {"summary": "Fix auth"}}|} };
  [%expect {||}];
  Io.Mocked.finish t

let%expect_test "lookup_cached_ticket: failure" =
  let creds = { base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = Io.Mocked.run (fun () ->
    match lookup_cached_ticket ~creds ~ticket:"BAD-999" with
    | Found _ -> Io.output "unexpected\n"
    | Not_found msg -> Io.output @@ sprintf "Not found: %s\n" msg)
  in
  [%expect {||}];
  Io.Mocked.http_get t { Io.status = 404; body = "Not Found" };
  [%expect {||}];
  Io.Mocked.finish t
```

**Step 3: Run tests, review, promote**

Run: `opam exec -- dune runtest`
Then: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 4: Commit**

```
git add lib/jira_search.ml lib/jira_search.mli
git commit -m 'feat: add cached ticket lookup with title display'
```

---

### Task 9: Integration — replace uncached entry prompts in main_logic

**Files:**
- Modify: `lib/main_logic.ml`

**Step 1: Build `jira_creds` in `run`**

In `main_logic.ml`, after credentials are collected and config is saved, construct the creds record and pass it into `run_day`:

```ocaml
let creds = { Jira_search.base_url = config.jira_base_url;
              email = config.jira_email; token = config.jira_token } in
```

Update `run_day` signature to accept `~creds` and `~starred_projects`.

**Step 2: Replace `prompt_uncached_entry`**

Replace the body of `prompt_uncached_entry` (or the call site in `run_day`) to use `Jira_search.prompt_loop`. Build the search hint from entry project + tag names:

```ocaml
let search_hint =
  let tag_names = List.map entry.Watson.tags ~f:(fun t -> t.Watson.name) in
  String.concat ~sep:" " (entry.Watson.project :: tag_names)
in
match Jira_search.prompt_loop ~creds ~search_hint
    ~has_tags:(not (List.is_empty entry.Watson.tags))
    ~starred_projects ~log_date:date with
| Jira_search.Selected result -> Processor.Accept result.key
| Jira_search.Skip_once -> Processor.Skip_once
| Jira_search.Skip_always -> Processor.Skip_always
| Jira_search.Split -> Processor.Split
```

**Step 3: Run tests — expect failures in E2E tests**

Run: `opam exec -- dune runtest`
Expected: E2E tests fail because prompts have changed and new HTTP calls are expected.
This is expected — do NOT fix E2E tests yet.

**Step 4: Commit**

```
git add lib/main_logic.ml
git commit -m 'feat: integrate Jira search into uncached entry prompts'
```

---

### Task 10: Integration — replace cached entry prompts in main_logic

**Files:**
- Modify: `lib/main_logic.ml`

**Step 1: Add ticket lookup before cached prompt**

In the cached ticket branch of `run_day`, before showing the cached prompt, call `Jira_search.lookup_cached_ticket`. On success, show the ticket summary in the prompt. On failure, warn, clear the mapping, and fall through to the uncached (search) flow:

```ocaml
| Some (Config.Ticket ticket) ->
  (match Jira_search.lookup_cached_ticket ~creds ~ticket with
   | Found result ->
     Io.output @@ sprintf "  [-> %s \"%s\"]\n" result.key result.summary;
     (* existing cached prompt: keep/change/skip *)
   | Not_found _msg ->
     (* clear mapping, fall through to uncached *)
     let cfg = { cfg with mappings =
       List.Assoc.remove cfg.mappings ~equal:String.equal entry.project } in
     run_uncached cfg entry)
```

**Step 2: Commit**

```
git add lib/main_logic.ml
git commit -m 'feat: add ticket title lookup for cached entries'
```

---

### Task 11: Integration — replace tag-level prompts

**Files:**
- Modify: `lib/main_logic.ml`

**Step 1: Update tag prompts to use search**

For uncached tags that don't match a ticket pattern, use `Jira_search.prompt_loop` with search hint `"project tag_name"`. Tags matching ticket patterns still auto-map but now validate via `Jira_search.lookup`.

For cached tags, use `Jira_search.lookup_cached_ticket` to show the title.

**Step 2: Commit**

```
git add lib/main_logic.ml
git commit -m 'feat: integrate Jira search into tag-level prompts'
```

---

### Task 12: Update E2E tests

**Files:**
- Modify: `test/test_e2e.ml`

**Step 1: Update all E2E tests for new prompt format**

Every test that currently shows:
```
  [ticket] assign | [n] skip | [S] skip always:
```
Now shows:
```
  [Enter] search "hint" | [ticket/search] | [n] skip | [S] skip always:
```

And every uncached ticket assignment now involves an `http_get` for validation.

Every cached entry now involves an `http_get` for title lookup.

Update each test one at a time:
1. Clear the expect blocks
2. Run `opam exec -- dune runtest` to see new output
3. Review the diff carefully
4. `opam exec -- dune promote`
5. Run again to confirm

Work through tests in order:
- `first-run: credentials, setup, and posting`
- `config round-trip: mappings persist across separate runs`
- `comprehensive interactive flow`
- `cached mappings: ticket and skip`
- `posting: success, failure, and issue lookup`
- `category selection and override`
- `multi-day with posting and skipping`
- `split by tags: full and partial`
- `failed credential API call aborts`
- `handles empty watson report`
- `cached ticket: keep all`
- `auto-detect: project name is ticket pattern`
- `cached skip: override with ticket`
- `composite key: split tag mapping doesn't apply to standalone project`

**Step 2: Run full test suite**

Run: `opam exec -- dune runtest`
Expected: All tests pass.

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m 'test: update E2E tests for Jira search integration'
```

---

### Task 13: MANUAL TESTING CHECKPOINT — full integration

> **STOP HERE.** Ask the user to manually test the full integrated flow:
>
> ```bash
> ./scripts/test-cli.sh restore
> ./scripts/test-cli.sh real
> ```
>
> Verify:
> 1. Uncached entries show search hint and search works
> 2. Cached entries show ticket title
> 3. Cached entry with deleted ticket shows warning and falls through
> 4. Direct ticket input validates against Jira
> 5. Split-by-tags works with search
> 6. Multi-day processing works correctly
> 7. Skip/skip-always still work

---

### Task 14: Cleanup — remove `--search` flag

**Files:**
- Modify: `bin/main.ml`

**Step 1: Remove the `--search` CLI flag**

Remove the `search_mode` named_opt and its handler from `bin/main.ml`.

**Step 2: Run tests**

Run: `opam exec -- dune runtest`
Expected: All tests pass.

**Step 3: Commit**

```
git add bin/main.ml
git commit -m 'chore: remove temporary --search CLI flag'
```
