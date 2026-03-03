# Jira Ticket Search & Completion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
>
> **Sub-agent instructions:** Do NOT use command substitution (`$(cat <<'EOF' ... EOF)`) in git commit commands. Use simple single-quoted strings instead.

**Goal:** Add inline Jira ticket search to ticket assignment prompts, with scoped JQL queries, input sanitization, and cached ticket title display.

**Architecture:** New `Jira_search` module owns all search/lookup/prompt logic, tested in isolation. Config gets a `starred_projects` field. Main_logic delegates to Jira_search for ticket assignment. Temporary `--search` CLI flag enables manual testing in isolation.

**Tech Stack:** OCaml 5.4, Effect handlers (Io module), Jira REST API v2 (`/rest/api/2/search`, `/rest/api/2/issue/{key}`), Re (regex), Yojson (JSON), Climate (CLI)

**Design doc:** `docs/plans/2026-03-03-jira-search-design.md`

---

### Task 1: Config & CLI — starred projects

Add `starred_projects` to config, `--star-projects` CLI command, and startup prompt when unconfigured.

**Files:**
- Modify: `lib/config.ml:21-34` (add field to type t)
- Modify: `lib/config.mli` (expose field if mli exposes type)
- Modify: `lib/ticket.ml` (add `is_project_key`)
- Modify: `lib/ticket.mli`
- Modify: `bin/main.ml` (add `--star-projects` flag)
- Modify: `lib/main_logic.ml` (add startup prompt for starred projects)

**Config.t change:**

Add to the `type t` record after `category_selections`:

```ocaml
  starred_projects : string list [@default []];
```

Add to `Config.empty`:

```ocaml
  starred_projects = [];
```

**Project key validation in Ticket module:**

```ocaml
let project_key_re = Re.Pcre.regexp {|^[A-Z][A-Z0-9_]+$|}
let is_project_key s = Re.execp project_key_re s
```

With inline expect test:

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

**CLI `--star-projects` flag in `bin/main.ml`:**

Add a new `named_opt`:

```ocaml
and+ star_projects = named_opt ~doc:"Comma-separated project keys to star" ["star-projects"] string
```

When provided, parse the comma-separated list, validate each key with `Ticket.is_project_key`, update config, save, and exit:

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

**Startup prompt for starred projects in `main_logic.ml`:**

In the `run` function, after credentials are collected and config is saved, if `config.starred_projects` is empty, prompt:

```ocaml
let config = if List.is_empty config.starred_projects then begin
  Io.output "No starred projects configured.\n";
  Io.output "Enter comma-separated Jira project keys to prioritise in search (e.g. DEV,ARCH): ";
  let input = Io.input () in
  let keys = String.split input ~on:',' |> List.map ~f:String.strip
    |> List.filter ~f:(fun s -> not (String.is_empty s)) in
  let valid_keys = List.filter keys ~f:Ticket.is_project_key in
  let invalid = List.filter keys ~f:(fun k -> not (Ticket.is_project_key k)) in
  if not (List.is_empty invalid) then
    Io.output @@ sprintf "  Skipping invalid keys: %s\n" (String.concat ~sep:", " invalid);
  if not (List.is_empty valid_keys) then
    Io.output @@ sprintf "Starred projects: %s\n" (String.concat ~sep:", " valid_keys);
  { config with starred_projects = valid_keys }
end else config in
```

**Testing:** Run `opam exec -- dune runtest` — all existing tests should pass thanks to `[@default []]`. The first-run E2E test will need updating to include the starred projects prompt — add the prompt/input exchange after the credential setup section. Promote and verify.

**Commit after all tests pass:**

```
git add lib/config.ml lib/config.mli lib/ticket.ml lib/ticket.mli bin/main.ml lib/main_logic.ml test/test_e2e.ml
git commit -m 'feat: add starred projects config, CLI command, and startup prompt'
```

---

### Task 2: Jira_search module — search in isolation

Build the complete `Jira_search` module with JQL sanitization, query building, API functions, prompt loop, and `--search` CLI flag. All tested in isolation before integration.

**Files:**
- Create: `lib/jira_search.ml`
- Create: `lib/jira_search.mli`
- Modify: `bin/main.ml` (add `--search` flag)

#### Part A: JQL sanitization (pure, unit tested)

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
```

Unit tests — empty expect blocks, run/review/promote:

```ocaml
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

#### Part B: JQL query building (pure, unit tested)

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

Unit tests:

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

#### Part C: Search and lookup API functions

Types:

```ocaml
type search_result = {
  key : string;
  summary : string;
  id : int;
}

type jira_creds = {
  base_url : string;
  email : string;
  token : string;
}
```

API functions:

```ocaml
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

let search ~creds ~jql =
  let encoded_jql = Uri.pct_encode jql in
  let url = sprintf "%s/rest/api/2/search?jql=%s&maxResults=5&fields=summary"
    creds.base_url encoded_jql in
  let headers = [jira_auth_header ~email:creds.email ~token:creds.token;
                 ("Accept", "application/json")] in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    Ok (parse_search_results response.body)
  else
    Error (sprintf "Jira search failed (%d): %s" response.status response.body)

let lookup ~creds ~ticket =
  let url = sprintf "%s/rest/api/2/issue/%s?fields=summary"
    creds.base_url (Uri.pct_encode ticket) in
  let headers = [jira_auth_header ~email:creds.email ~token:creds.token;
                 ("Accept", "application/json")] in
  let response = Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    parse_single_issue response.body
  else
    Error (sprintf "not found (%d)" response.status)
```

Unit tests for JSON parsing + mocked IO tests for search/lookup:

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

let%expect_test "search: success" =
  let creds = { base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = Io.Mocked.run (fun () ->
    match search ~creds ~jql:{|text ~ "coding"|} with
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
  let creds = { base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = Io.Mocked.run (fun () ->
    match search ~creds ~jql:{|text ~ "test"|} with
    | Ok _ -> Io.output "unexpected success\n"
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 401; body = "Unauthorized" };
  [%expect {||}];
  Io.Mocked.finish t

let%expect_test "lookup: success" =
  let creds = { base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = Io.Mocked.run (fun () ->
    match lookup ~creds ~ticket:"DEV-123" with
    | Ok r -> Io.output @@ sprintf "%s: %s (id=%d)\n" r.key r.summary r.id
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 200;
    body = {|{"id": "999", "key": "DEV-123", "fields": {"summary": "Fix auth"}}|} };
  [%expect {||}];
  Io.Mocked.finish t

let%expect_test "lookup: not found" =
  let creds = { base_url = "https://test.atlassian.net"; email = "u@t.com"; token = "t" } in
  let t = Io.Mocked.run (fun () ->
    match lookup ~creds ~ticket:"BAD-999" with
    | Ok _ -> Io.output "unexpected\n"
    | Error e -> Io.output @@ sprintf "Error: %s\n" e)
  in
  Io.Mocked.http_get t { Io.status = 404; body = "Not Found" };
  [%expect {||}];
  Io.Mocked.finish t
```

#### Part D: Prompt loop and cached ticket lookup

Prompt outcome type:

```ocaml
type prompt_outcome =
  | Selected of search_result
  | Skip_once
  | Skip_always
  | Split

type lookup_result =
  | Found of search_result
  | Not_found of string
```

Interactive prompt loop — the core search-select interaction:

```ocaml
let display_results results =
  List.iteri results ~f:(fun i r ->
    Io.output @@ sprintf "  %d. %-10s %s\n" (i + 1) r.key r.summary)

let rec results_loop ~creds ~starred_projects ~log_date ~results =
  Io.output "  [#] select | [text] search again | [n] back: ";
  let input = Io.input () in
  match input with
  | "n" -> None
  | s when Ticket.is_ticket_pattern s -> handle_ticket_input ~creds ~starred_projects ~log_date s
  | s ->
    (match Int.of_string_opt s with
     | Some n when n >= 1 && n <= List.length results ->
       Some (List.nth_exn results (n - 1))
     | _ -> search_and_display ~creds ~starred_projects ~log_date s)

and handle_ticket_input ~creds ~starred_projects:_ ~log_date:_ ticket =
  Io.output @@ sprintf "  Looking up %s... " ticket;
  match lookup ~creds ~ticket with
  | Ok result ->
    Io.output @@ sprintf "\n  %s  %s\n" result.key result.summary;
    Io.output "  [Enter] confirm | [text] search again | [n] back: ";
    (match Io.input () with
     | "" -> Some result
     | "n" -> None
     | s -> search_and_display ~creds ~starred_projects:[] ~log_date:"2026-01-01" s)
  | Error msg ->
    Io.output @@ sprintf "%s\n" msg;
    Io.output "  [text] try again | [n] back: ";
    (match Io.input () with
     | "n" -> None
     | s when Ticket.is_ticket_pattern s ->
       handle_ticket_input ~creds ~starred_projects:[] ~log_date:"2026-01-01" s
     | s -> search_and_display ~creds ~starred_projects:[] ~log_date:"2026-01-01" s)

and search_and_display ~creds ~starred_projects ~log_date terms =
  match build_search_jql ~terms ~starred_projects ~log_date with
  | None ->
    Io.output "  No search terms provided.\n";
    None
  | Some jql ->
    match search ~creds ~jql with
    | Ok [] ->
      Io.output "  No results found.\n";
      Io.output "  [text] search again | [n] back: ";
      (match Io.input () with
       | "n" -> None
       | s -> search_and_display ~creds ~starred_projects ~log_date s)
    | Ok results ->
      display_results results;
      results_loop ~creds ~starred_projects ~log_date ~results
    | Error msg ->
      Io.output @@ sprintf "  Search failed: %s\n" msg;
      None
```

Main entry point:

```ocaml
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
```

Cached ticket lookup:

```ocaml
let lookup_cached_ticket ~creds ~ticket =
  Io.output @@ sprintf "  Looking up %s... " ticket;
  match lookup ~creds ~ticket with
  | Ok result ->
    Io.output "OK\n";
    Found result
  | Error msg ->
    Io.output @@ sprintf "%s\n" msg;
    Not_found msg
```

Mocked IO tests for prompt loop — cover these scenarios:
1. User hits Enter → search returns results → user selects #1
2. User types ticket key → lookup succeeds → user confirms
3. User types ticket key → lookup fails → user types `n` to go back
4. User types search terms → gets results → searches again → selects
5. User types `n` to skip, `S` to skip always, `s` to split
6. Empty search results → "no results" message
7. `lookup_cached_ticket` success and failure

Example test pattern:

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
  [%expect {||}];
  Io.Mocked.input t "";
  [%expect {||}];
  Io.Mocked.http_get t { Io.status = 200; body = {|{"issues": [
    {"id": "10", "key": "CODE-42", "fields": {"summary": "Refactor auth"}}
  ]}|} };
  [%expect {||}];
  Io.Mocked.input t "1";
  [%expect {||}];
  Io.Mocked.finish t
```

#### Part E: `--search` CLI flag

Add to `bin/main.ml`:

```ocaml
and+ search_mode = named_opt ~doc:"Test search prompt in isolation" ["search"] string
```

When `search_mode` is `Some search_terms`:
1. Load config
2. Verify Jira credentials are present (fail with helpful message if not)
3. Build `Jira_search.jira_creds` from config
4. Call `Jira_search.prompt_loop` with the search terms as hint, today's date as log_date
5. Print the outcome and exit

This runs inside `Io.with_stdio` so it uses real HTTP and real stdin/stdout.

#### Expose in `lib/jira_search.mli`:

```ocaml
type search_result = { key : string; summary : string; id : int }

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

type lookup_result =
  | Found of search_result
  | Not_found of string

val sanitize_jql_text : string -> string option
val validate_project_key : string -> bool
val build_search_jql : terms:string -> starred_projects:string list -> log_date:string -> string option
val parse_search_results : string -> search_result list
val parse_single_issue : string -> (search_result, string) result
val search : creds:jira_creds -> jql:string -> (search_result list, string) result
val lookup : creds:jira_creds -> ticket:string -> (search_result, string) result
val lookup_cached_ticket : creds:jira_creds -> ticket:string -> lookup_result
val prompt_loop : creds:jira_creds -> search_hint:string -> has_tags:bool -> starred_projects:string list -> log_date:string -> prompt_outcome
```

**Testing:** Run/review/promote throughout. All inline and mocked IO tests should pass before proceeding.

**Commit after all tests pass:**

```
git add lib/jira_search.ml lib/jira_search.mli bin/main.ml
git commit -m 'feat: add Jira_search module with search, lookup, and prompt loop'
```

#### MANUAL TESTING CHECKPOINT

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
> 2. Results display correctly with key + summary (up to 5)
> 3. Selecting a result by number works
> 4. Typing a ticket key does a direct lookup
> 5. Error cases (bad credentials, no results) show helpful messages
>
> Report any issues before proceeding to integration.

---

### Task 3: Integration — wire Jira search into main_logic (TDD)

Replace all ticket prompts in `main_logic.ml` with `Jira_search` calls, updating E2E tests as you go (test-driven — update each E2E test immediately after changing the code path it covers).

**Files:**
- Modify: `lib/main_logic.ml`
- Modify: `test/test_e2e.ml`

#### Part A: Wire up creds and starred_projects

In `main_logic.ml`, after credentials are collected and config is saved:

```ocaml
let creds = { Jira_search.base_url = config.jira_base_url;
              email = config.jira_email; token = config.jira_token } in
```

Update `run_day` signature to accept `~creds` and pass `config.starred_projects` through.

#### Part B: Replace uncached entry prompt

Replace `prompt_uncached_entry` (or its call site in `run_day`) to use `Jira_search.prompt_loop`. Build search hint from entry project + tag names:

```ocaml
let search_hint =
  let tag_names = List.map entry.Watson.tags ~f:(fun t -> t.Watson.name) in
  String.concat ~sep:" " (entry.Watson.project :: tag_names)
in
match Jira_search.prompt_loop ~creds ~search_hint
    ~has_tags:(not (List.is_empty entry.Watson.tags))
    ~starred_projects:config.starred_projects ~log_date:date with
| Jira_search.Selected result -> Processor.Accept result.key
| Jira_search.Skip_once -> Processor.Skip_once
| Jira_search.Skip_always -> Processor.Skip_always
| Jira_search.Split -> Processor.Split
```

**Immediately update affected E2E tests:** Every test with an uncached entry prompt changes format and now requires `http_get` responses for search/lookup. Work through each test: clear its expect blocks, run `opam exec -- dune runtest`, review the diff, promote.

#### Part C: Replace cached entry prompt

In the cached ticket branch of `run_day`, add `Jira_search.lookup_cached_ticket` before displaying the cached prompt:

```ocaml
| Some (Config.Ticket ticket) ->
  (match Jira_search.lookup_cached_ticket ~creds ~ticket with
   | Found result ->
     Io.output @@ sprintf "  [-> %s \"%s\"]\n" result.key result.summary;
     (* existing cached prompt logic: keep/change/skip *)
   | Not_found _msg ->
     (* clear mapping, fall through to uncached *)
     let cfg = { cfg with mappings =
       List.Assoc.remove cfg.mappings ~equal:String.equal mapping_key } in
     run_uncached cfg entry)
```

**Immediately update affected E2E tests.** Every cached entry test now requires an `http_get` for the title lookup.

#### Part D: Replace tag-level prompts

For uncached tags that don't match a ticket pattern, use `Jira_search.prompt_loop` with search hint `"project tag_name"`. Tags matching ticket patterns still auto-map but now validate via `Jira_search.lookup`.

For cached tags, use `Jira_search.lookup_cached_ticket` to show the title.

**Immediately update affected E2E tests.**

#### Part E: Full test suite green

Run: `opam exec -- dune runtest`
Expected: All tests pass — both inline Jira_search tests and E2E tests.

**Commit:**

```
git add lib/main_logic.ml test/test_e2e.ml
git commit -m 'feat: integrate Jira search into all ticket prompts'
```

#### MANUAL TESTING CHECKPOINT

> **STOP HERE.** Ask the user to manually test the full integrated flow:
>
> ```bash
> ./scripts/test-cli.sh restore
> ./scripts/test-cli.sh real
> ```
>
> Verify:
> 1. Uncached entries show search hint and search works
> 2. Cached entries show ticket title from Jira
> 3. Cached entry with deleted/moved ticket shows warning and falls through to search
> 4. Direct ticket input validates against Jira
> 5. Split-by-tags works with search for non-ticket tags
> 6. Multi-day processing works correctly
> 7. Skip/skip-always still work
> 8. Starred projects prompt appears on first run
