# Watsup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an OCaml CLI that reads Watson time tracking reports and posts worklogs to Jira Tempo with interactive mapping.

**Architecture:** Parser combinator (Angstrom) for Watson output, interactive terminal prompts with cached mappings in sexp format, HTTP client for Tempo API, batch posting workflow.

**Tech Stack:** OCaml 5.4, Core, Angstrom, Cohttp-lwt-unix, ppx_jane, ppx_expect, ppx_inline_test

---

## Task 1: Project Scaffolding

**Files:**
- Create: `dune-project`
- Create: `bin/dune`
- Create: `bin/main.ml`
- Create: `lib/dune`
- Create: `watsup.opam` (generated)

**Step 1: Create opam switch**

Run:
```bash
opam switch create . 5.4.0 --no-install
eval $(opam env)
```

Expected: Switch created, OCaml 5.4.0 active

**Step 2: Initialize dune project**

Run:
```bash
dune init project watsup
```

Expected: Basic project structure created

**Step 3: Update dune-project with dependencies**

Replace `dune-project` contents:

```dune
(lang dune 3.16)
(name watsup)

(generate_opam_files true)

(package
 (name watsup)
 (synopsis "Watson to Jira Tempo CLI")
 (depends
  (ocaml (>= 5.4.0))
  (core (>= 0.17))
  (core_unix (>= 0.17))
  (angstrom (>= 0.16))
  (cohttp-lwt-unix (>= 6.0))
  (lwt (>= 5.7))
  (yojson (>= 2.1))
  (ppx_jane (>= 0.17))
  (ppx_expect (>= 0.17))
  (ppx_inline_test (>= 0.17))))
```

**Step 4: Update lib/dune for Core and PPX**

Replace `lib/dune` contents:

```dune
(library
 (name watsup)
 (libraries core core_unix angstrom cohttp-lwt-unix lwt yojson)
 (preprocess (pps ppx_jane))
 (inline_tests))
```

**Step 5: Update bin/dune**

Replace `bin/dune` contents:

```dune
(executable
 (name main)
 (public_name watsup)
 (libraries watsup core core_unix)
 (preprocess (pps ppx_jane)))
```

**Step 6: Create minimal main.ml**

Replace `bin/main.ml` contents:

```ocaml
open Core

let () =
  print_endline "watsup: Watson to Tempo"
```

**Step 7: Install dependencies**

Run:
```bash
opam install . --deps-only -y
```

Expected: All dependencies installed

**Step 8: Build and test**

Run:
```bash
dune build
dune exec watsup
```

Expected: Prints "watsup: Watson to Tempo"

**Step 9: Commit**

```bash
git add -A
git commit -m "feat: initialize project with dune and dependencies"
```

---

## Task 2: Duration Module

**Files:**
- Create: `lib/duration.mli`
- Create: `lib/duration.ml`

**Step 1: Write duration.mli interface**

Create `lib/duration.mli`:

```ocaml
open Core

type t [@@deriving sexp, compare, equal]

val of_hms : hours:int -> mins:int -> secs:int -> t
val of_seconds : int -> t
val to_seconds : t -> int
val to_minutes : t -> int
val round_5min : t -> t
val to_string : t -> string
val zero : t
val ( + ) : t -> t -> t
```

**Step 2: Write failing test for duration parsing**

Create `lib/duration.ml`:

```ocaml
open Core

type t = int [@@deriving sexp, compare, equal]  (* seconds *)

let of_hms ~hours ~mins ~secs = (hours * 3600) + (mins * 60) + secs
let of_seconds s = s
let to_seconds t = t
let to_minutes t = t / 60
let zero = 0
let ( + ) = Int.( + )

let round_5min t =
  let mins = to_minutes t in
  let rounded = ((mins + 2) / 5) * 5 in
  of_seconds (rounded * 60)

let to_string t =
  let total_mins = to_minutes t in
  let hours = total_mins / 60 in
  let mins = total_mins mod 60 in
  match hours, mins with
  | 0, m -> sprintf "%dm" m
  | h, 0 -> sprintf "%dh" h
  | h, m -> sprintf "%dh %dm" h m

let%expect_test "of_hms" =
  let d = of_hms ~hours:2 ~mins:28 ~secs:32 in
  print_s [%sexp (to_seconds d : int)];
  [%expect {| 8912 |}]

let%expect_test "round_5min rounds up from 3" =
  let d = of_hms ~hours:0 ~mins:28 ~secs:0 in
  let rounded = round_5min d in
  print_s [%sexp (to_minutes rounded : int)];
  [%expect {| 30 |}]

let%expect_test "round_5min rounds down from 2" =
  let d = of_hms ~hours:0 ~mins:32 ~secs:0 in
  let rounded = round_5min d in
  print_s [%sexp (to_minutes rounded : int)];
  [%expect {| 30 |}]

let%expect_test "round_5min 33 -> 35" =
  let d = of_hms ~hours:0 ~mins:33 ~secs:0 in
  let rounded = round_5min d in
  print_s [%sexp (to_minutes rounded : int)];
  [%expect {| 35 |}]

let%expect_test "to_string" =
  print_endline (to_string (of_hms ~hours:2 ~mins:30 ~secs:0));
  [%expect {| 2h 30m |}];
  print_endline (to_string (of_hms ~hours:0 ~mins:45 ~secs:0));
  [%expect {| 45m |}];
  print_endline (to_string (of_hms ~hours:1 ~mins:0 ~secs:0));
  [%expect {| 1h |}]
```

**Step 3: Run tests**

Run:
```bash
dune runtest
```

Expected: All tests pass

**Step 4: Commit**

```bash
git add lib/duration.ml lib/duration.mli
git commit -m "feat: add Duration module with rounding"
```

---

## Task 3: Ticket Pattern Module

**Files:**
- Create: `lib/ticket.mli`
- Create: `lib/ticket.ml`

**Step 1: Write ticket.mli interface**

Create `lib/ticket.mli`:

```ocaml
val is_ticket_pattern : string -> bool
val extract_tickets : string list -> string list
```

**Step 2: Write implementation with tests**

Create `lib/ticket.ml`:

```ocaml
open Core

let ticket_re = Re.Pcre.regexp {|^[A-Z]+-[0-9]+$|}

let is_ticket_pattern s =
  Re.execp ticket_re s

let extract_tickets tags =
  List.filter tags ~f:is_ticket_pattern

let%expect_test "is_ticket_pattern valid" =
  print_s [%sexp (is_ticket_pattern "FK-3080" : bool)];
  [%expect {| true |}];
  print_s [%sexp (is_ticket_pattern "CHIM-850" : bool)];
  [%expect {| true |}];
  print_s [%sexp (is_ticket_pattern "LOG-16" : bool)];
  [%expect {| true |}]

let%expect_test "is_ticket_pattern invalid" =
  print_s [%sexp (is_ticket_pattern "jack" : bool)];
  [%expect {| false |}];
  print_s [%sexp (is_ticket_pattern "tomasz" : bool)];
  [%expect {| false |}];
  print_s [%sexp (is_ticket_pattern "setup" : bool)];
  [%expect {| false |}];
  print_s [%sexp (is_ticket_pattern "FK3080" : bool)];
  [%expect {| false |}]

let%expect_test "extract_tickets" =
  let tags = ["CHIM-850"; "FK-3080"; "jack"; "liam"; "FK-3083"] in
  let tickets = extract_tickets tags in
  print_s [%sexp (tickets : string list)];
  [%expect {| (CHIM-850 FK-3080 FK-3083) |}]
```

**Step 3: Add re dependency to dune-project**

Add `(re (>= 1.11))` to depends in `dune-project`

**Step 4: Add re to lib/dune libraries**

Update libraries line: `(libraries core core_unix angstrom cohttp-lwt-unix lwt yojson re)`

**Step 5: Reinstall deps and run tests**

Run:
```bash
opam install . --deps-only -y
dune runtest
```

Expected: All tests pass

**Step 6: Commit**

```bash
git add lib/ticket.ml lib/ticket.mli lib/dune dune-project
git commit -m "feat: add Ticket module for pattern matching"
```

---

## Task 4: Watson Entry Types

**Files:**
- Create: `lib/watson.mli`
- Create: `lib/watson.ml`

**Step 1: Write watson.mli interface**

Create `lib/watson.mli`:

```ocaml
open Core

type tag = {
  name : string;
  duration : Duration.t;
} [@@deriving sexp]

type entry = {
  project : string;
  total : Duration.t;
  tags : tag list;
} [@@deriving sexp]

type report = {
  date_range : string;
  entries : entry list;
  total : Duration.t;
} [@@deriving sexp]

val parse : string -> report Or_error.t
```

**Step 2: Write basic types (no parser yet)**

Create `lib/watson.ml`:

```ocaml
open Core

type tag = {
  name : string;
  duration : Duration.t;
} [@@deriving sexp]

type entry = {
  project : string;
  total : Duration.t;
  tags : tag list;
} [@@deriving sexp]

type report = {
  date_range : string;
  entries : entry list;
  total : Duration.t;
} [@@deriving sexp]

let parse _input =
  Or_error.error_string "not implemented"
```

**Step 3: Build to verify types compile**

Run:
```bash
dune build
```

Expected: Builds successfully

**Step 4: Commit**

```bash
git add lib/watson.ml lib/watson.mli
git commit -m "feat: add Watson entry types"
```

---

## Task 5: Watson Parser

**Files:**
- Modify: `lib/watson.ml`

**Step 1: Add duration parser**

Add to `lib/watson.ml` after types:

```ocaml
open Angstrom

let ws = skip_while (fun c -> Char.equal c ' ')
let digits = take_while1 (fun c -> Char.is_digit c) >>| Int.of_string

let duration_part suffix =
  option 0 (digits <* char suffix <* ws)

let duration_p =
  let* hours = duration_part 'h' in
  let* mins = duration_part 'm' in
  let* secs = duration_part 's' in
  return (Duration.of_hms ~hours ~mins ~secs)

let%expect_test "parse duration" =
  let test s =
    match parse_string ~consume:Prefix duration_p s with
    | Ok d -> print_s [%sexp (Duration.to_seconds d : int)]
    | Error e -> print_endline e
  in
  test "2h 28m 32s";
  [%expect {| 8912 |}];
  test "1h 29m 04s";
  [%expect {| 5344 |}];
  test "59m 28s";
  [%expect {| 3568 |}];
  test "25m 46s";
  [%expect {| 1546 |}]
```

**Step 2: Run tests**

Run:
```bash
dune runtest
```

Expected: All tests pass

**Step 3: Add tag parser**

Add after duration parser:

```ocaml
let tag_name = take_while1 (fun c -> not (Char.is_whitespace c) && not (Char.equal c ']'))

let tag_line =
  let* _ = char '\t' *> char '[' in
  let* name = tag_name <* ws in
  let* dur = duration_p <* char ']' in
  return { name; duration = dur }

let%expect_test "parse tag line" =
  let test s =
    match parse_string ~consume:Prefix tag_line s with
    | Ok t -> print_s [%sexp (t : tag)]
    | Error e -> print_endline e
  in
  test "\t[setup  1h 29m 04s]";
  [%expect {| ((name setup) (duration 5344)) |}];
  test "\t[FK-3080     33m 35s]";
  [%expect {| ((name FK-3080) (duration 2015)) |}]
```

**Step 4: Run tests**

Run:
```bash
dune runtest
```

Expected: All tests pass

**Step 5: Add project line parser**

Add after tag parser:

```ocaml
let project_name = take_while1 (fun c -> not (Char.is_whitespace c) && not (Char.equal c '-'))

let project_line =
  let* name = project_name <* ws in
  let* _ = char '-' <* ws in
  let* dur = duration_p in
  return (name, dur)

let%expect_test "parse project line" =
  let test s =
    match parse_string ~consume:Prefix project_line s with
    | Ok (name, dur) -> print_s [%sexp ((name, Duration.to_seconds dur) : string * int)]
    | Error e -> print_endline e
  in
  test "packaday - 2h 28m 32s";
  [%expect {| (packaday 8912) |}];
  test "cr - 51m 02s";
  [%expect {| (cr 3062) |}]
```

**Step 6: Run tests**

Run:
```bash
dune runtest
```

Expected: All tests pass

**Step 7: Add entry parser**

Add after project line parser:

```ocaml
let newline = char '\n'

let entry_p =
  let* (name, total) = project_line <* newline in
  let* tags = many (tag_line <* newline) in
  return { project = name; total; tags }

let%expect_test "parse entry" =
  let input = "packaday - 2h 28m 32s\n\t[setup  1h 29m 04s]\n\t[shapes     59m 28s]\n" in
  match parse_string ~consume:Prefix entry_p input with
  | Ok e -> print_s [%sexp (e : entry)]
  | Error e -> print_endline e
  [@@expect {|
    ((project packaday) (total 8912)
     (tags (((name setup) (duration 5344)) ((name shapes) (duration 3568)))))
  |}]
```

**Step 8: Run tests**

Run:
```bash
dune runtest
```

Expected: All tests pass

**Step 9: Add full report parser**

Add after entry parser:

```ocaml
let date_range_line = take_till (Char.equal '\n') <* newline

let blank_line = newline

let total_line =
  let* _ = string "Total: " in
  duration_p

let report_p =
  let* date_range = date_range_line in
  let* _ = blank_line in
  let* entries = many entry_p in
  let* _ = many blank_line in
  let* total = total_line in
  return { date_range; entries; total }

let parse input =
  match parse_string ~consume:Prefix report_p input with
  | Ok report -> Ok report
  | Error msg -> Or_error.error_string msg

let%expect_test "parse full report" =
  let input = {|Tue 03 February 2026 -> Tue 03 February 2026

architecture - 25m 46s

breaks - 1h 20m 39s
	[coffee     20m 55s]
	[lunch     59m 44s]

cr - 51m 02s
	[FK-3080     33m 35s]
	[FK-3083     12m 37s]

Total: 2h 37m 27s|} in
  match parse input with
  | Ok r ->
    print_s [%sexp (List.length r.entries : int)];
    [%expect {| 3 |}];
    print_s [%sexp (r.date_range : string)];
    [%expect {| "Tue 03 February 2026 -> Tue 03 February 2026" |}]
  | Error e ->
    print_s [%sexp (e : Error.t)]
```

**Step 10: Run tests**

Run:
```bash
dune runtest
```

Expected: All tests pass

**Step 11: Commit**

```bash
git add lib/watson.ml
git commit -m "feat: add Watson report parser with Angstrom"
```

---

## Task 6: Config Types and Persistence

**Files:**
- Create: `lib/config.mli`
- Create: `lib/config.ml`

**Step 1: Write config.mli interface**

Create `lib/config.mli`:

```ocaml
open Core

type mapping =
  | Ticket of string
  | Skip
  | Auto_extract
[@@deriving sexp]

type category_cache = {
  selected : string;
  options : string list;
  fetched_at : Time.t;
} [@@deriving sexp]

type t = {
  tempo_token : string;
  category : category_cache option;
  mappings : (string * mapping) list;
} [@@deriving sexp]

val default_path : unit -> string
val load : path:string -> t Or_error.t
val save : path:string -> t -> unit Or_error.t
val empty : t
val get_mapping : t -> string -> mapping option
val set_mapping : t -> string -> mapping -> t
```

**Step 2: Write implementation with tests**

Create `lib/config.ml`:

```ocaml
open Core

type mapping =
  | Ticket of string
  | Skip
  | Auto_extract
[@@deriving sexp]

type category_cache = {
  selected : string;
  options : string list;
  fetched_at : Time.t;
} [@@deriving sexp]

type t = {
  tempo_token : string;
  category : category_cache option;
  mappings : (string * mapping) list;
} [@@deriving sexp]

let default_path () =
  let home = Sys.getenv_exn "HOME" in
  home ^/ ".config" ^/ "watsup" ^/ "config.sexp"

let empty = {
  tempo_token = "";
  category = None;
  mappings = [];
}

let load ~path =
  match Sys_unix.file_exists path with
  | `Yes ->
    (try
      let contents = In_channel.read_all path in
      let sexp = Sexp.of_string contents in
      Ok (t_of_sexp sexp)
    with exn ->
      Or_error.error_string (Exn.to_string exn))
  | `No | `Unknown ->
    Ok empty

let save ~path config =
  try
    let dir = Filename.dirname path in
    Core_unix.mkdir_p dir;
    let sexp = sexp_of_t config in
    Out_channel.write_all path ~data:(Sexp.to_string_hum sexp);
    Ok ()
  with exn ->
    Or_error.error_string (Exn.to_string exn)

let get_mapping config project =
  List.Assoc.find config.mappings ~equal:String.equal project

let set_mapping config project mapping =
  let mappings = List.Assoc.add config.mappings ~equal:String.equal project mapping in
  { config with mappings }

let%expect_test "config round trip" =
  let path = Filename_unix.temp_file "watsup_test" ".sexp" in
  let config = {
    tempo_token = "test-token";
    category = None;
    mappings = [("breaks", Skip); ("proj", Ticket "LOG-16")];
  } in
  save ~path config |> Or_error.ok_exn;
  let loaded = load ~path |> Or_error.ok_exn in
  print_s [%sexp (loaded.tempo_token : string)];
  [%expect {| test-token |}];
  print_s [%sexp (loaded.mappings : (string * mapping) list)];
  [%expect {| ((breaks Skip) (proj (Ticket LOG-16))) |}];
  Core_unix.unlink path

let%expect_test "get_mapping" =
  let config = {
    tempo_token = "";
    category = None;
    mappings = [("proj", Ticket "LOG-16"); ("breaks", Skip)];
  } in
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
```

**Step 3: Run tests**

Run:
```bash
dune runtest
```

Expected: All tests pass

**Step 4: Commit**

```bash
git add lib/config.ml lib/config.mli
git commit -m "feat: add Config module with sexp persistence"
```

---

## Task 7: Worklog Types

**Files:**
- Create: `lib/worklog.mli`
- Create: `lib/worklog.ml`

**Step 1: Write worklog.mli interface**

Create `lib/worklog.mli`:

```ocaml
open Core

type t = {
  ticket : string;
  duration : Duration.t;
  date : Date.t;
  category : string;
  account : string option;
  message : string option;
  source : string;  (* watson project/tag for display *)
} [@@deriving sexp]

type post_result =
  | Posted
  | Failed of string
  | Manual_required of string
[@@deriving sexp]
```

**Step 2: Write implementation**

Create `lib/worklog.ml`:

```ocaml
open Core

type t = {
  ticket : string;
  duration : Duration.t;
  date : Date.t;
  category : string;
  account : string option;
  message : string option;
  source : string;
} [@@deriving sexp]

type post_result =
  | Posted
  | Failed of string
  | Manual_required of string
[@@deriving sexp]
```

**Step 3: Build to verify types compile**

Run:
```bash
dune build
```

Expected: Builds successfully

**Step 4: Commit**

```bash
git add lib/worklog.ml lib/worklog.mli
git commit -m "feat: add Worklog types"
```

---

## Task 8: Tempo API Client (Types and Stubs)

**Files:**
- Create: `lib/tempo.mli`
- Create: `lib/tempo.ml`

**Step 1: Write tempo.mli interface**

Create `lib/tempo.mli`:

```ocaml
open Core

type category = {
  id : int;
  name : string;
} [@@deriving sexp]

type account = {
  id : int;
  name : string;
} [@@deriving sexp]

val fetch_categories : token:string -> category list Or_error.t Lwt.t
val fetch_account_for_ticket : token:string -> ticket:string -> account option Or_error.t Lwt.t
val post_worklog : token:string -> Worklog.t -> Worklog.post_result Lwt.t
```

**Step 2: Write stub implementation**

Create `lib/tempo.ml`:

```ocaml
open Core

type category = {
  id : int;
  name : string;
} [@@deriving sexp]

type account = {
  id : int;
  name : string;
} [@@deriving sexp]

(* TODO: Implement actual API calls *)

let fetch_categories ~token:_ =
  Lwt.return (Ok [
    { id = 1; name = "Development" };
    { id = 2; name = "Meeting" };
    { id = 3; name = "Support" };
  ])

let fetch_account_for_ticket ~token:_ ~ticket:_ =
  Lwt.return (Ok (Some { id = 1; name = "Default Account" }))

let post_worklog ~token:_ _worklog =
  Lwt.return Worklog.Posted
```

**Step 3: Build to verify types compile**

Run:
```bash
dune build
```

Expected: Builds successfully

**Step 4: Commit**

```bash
git add lib/tempo.ml lib/tempo.mli
git commit -m "feat: add Tempo API client stubs"
```

---

## Task 9: Interactive Prompt Module

**Files:**
- Create: `lib/prompt.mli`
- Create: `lib/prompt.ml`

**Step 1: Write prompt.mli interface**

Create `lib/prompt.mli`:

```ocaml
open Core

type action =
  | Accept of string           (* ticket number *)
  | Skip                       (* one-time skip *)
  | Skip_always                (* cache skip *)
  | Split                      (* split into tags *)
  | Set_message of string
  | Change_category
  | Quit
[@@deriving sexp]

val prompt_entry : Watson.entry -> cached:Config.mapping option -> category:string -> action
val prompt_tag : project:string -> Watson.tag -> action
val prompt_ticket : default:string option -> string
val prompt_confirm_post : Worklog.t list -> skipped:(string * Duration.t) list -> manual:(string * Duration.t) list -> bool
val prompt_token : unit -> string
val prompt_category : Tempo.category list -> current:string option -> string
```

**Step 2: Write basic implementation**

Create `lib/prompt.ml`:

```ocaml
open Core

type action =
  | Accept of string
  | Skip
  | Skip_always
  | Split
  | Set_message of string
  | Change_category
  | Quit
[@@deriving sexp]

let read_line_safe () =
  match In_channel.(input_line stdin) with
  | Some line -> line
  | None -> ""

let prompt_entry entry ~cached ~category =
  let open Watson in
  printf "\n%s - %s\n" entry.project (Duration.to_string (Duration.round_5min entry.total));
  (match cached with
   | Some (Config.Ticket t) -> printf "  Cached: %s\n" t
   | Some Config.Skip -> printf "  Cached: SKIP\n"
   | Some Config.Auto_extract -> printf "  Auto-extract mode\n"
   | None -> ());
  printf "  [Enter] accept | [ticket] override | [s]plit | [n]skip | [S]kip always\n";
  printf "  [m]essage | [c]ategory (current: %s) | [q]uit\n" category;
  printf "> %!";
  let input = read_line_safe () in
  match input with
  | "" ->
    (match cached with
     | Some (Config.Ticket t) -> Accept t
     | _ -> Skip)
  | "s" -> Split
  | "n" -> Skip
  | "S" -> Skip_always
  | "c" -> Change_category
  | "q" -> Quit
  | s when String.is_prefix s ~prefix:"m " ->
    Set_message (String.chop_prefix_exn s ~prefix:"m ")
  | ticket -> Accept ticket

let prompt_tag ~project tag =
  let open Watson in
  printf "\n%s [%s] - %s\n" project tag.name (Duration.to_string (Duration.round_5min tag.duration));
  printf "  [ticket] assign | [n]skip | [q]uit split\n";
  printf "> %!";
  let input = read_line_safe () in
  match input with
  | "n" -> Skip
  | "q" -> Quit
  | "" -> Skip
  | ticket -> Accept ticket

let prompt_ticket ~default =
  (match default with
   | Some t -> printf "Ticket [%s]: %!" t
   | None -> printf "Ticket: %!");
  let input = read_line_safe () in
  match input, default with
  | "", Some t -> t
  | "", None -> ""
  | s, _ -> s

let prompt_confirm_post worklogs ~skipped ~manual =
  printf "\n=== Worklogs to Post ===\n";
  List.iter worklogs ~f:(fun w ->
    printf "%-12s %-15s %8s  %s\n"
      w.Worklog.ticket
      w.source
      (Duration.to_string w.duration)
      w.category);
  let total = List.fold worklogs ~init:Duration.zero ~f:(fun acc w ->
    Duration.(acc + w.Worklog.duration)) in
  printf "                        ------\n";
  printf "Total:                  %8s  (target: 7h 30m)\n" (Duration.to_string total);
  if not (List.is_empty skipped) then begin
    printf "\n=== Skipped (cached) ===\n";
    List.iter skipped ~f:(fun (name, dur) ->
      printf "%-28s %8s\n" name (Duration.to_string dur))
  end;
  if not (List.is_empty manual) then begin
    printf "\n=== Manual Required (no Account) ===\n";
    List.iter manual ~f:(fun (name, dur) ->
      printf "%-28s %8s  [no account found]\n" name (Duration.to_string dur))
  end;
  printf "\n[Enter] post all | [q]uit without posting\n";
  printf "> %!";
  let input = read_line_safe () in
  not (String.equal input "q")

let prompt_token () =
  printf "Enter Tempo API token: %!";
  read_line_safe ()

let prompt_category categories ~current =
  printf "\nSelect category:\n";
  List.iteri categories ~f:(fun i c ->
    let marker = match current with
      | Some cur when String.equal cur c.Tempo.name -> " *"
      | _ -> ""
    in
    printf "  %d. %s%s\n" (i + 1) c.name marker);
  printf "  [r] refresh from API\n";
  printf "> %!";
  let input = read_line_safe () in
  match Int.of_string_opt input with
  | Some n when n > 0 && n <= List.length categories ->
    (List.nth_exn categories (n - 1)).name
  | _ ->
    (match current with Some c -> c | None -> "Development")
```

**Step 3: Build to verify**

Run:
```bash
dune build
```

Expected: Builds successfully

**Step 4: Commit**

```bash
git add lib/prompt.ml lib/prompt.mli
git commit -m "feat: add interactive Prompt module"
```

---

## Task 10: Main CLI Entry Point

**Files:**
- Modify: `bin/main.ml`

**Step 1: Implement main CLI flow**

Replace `bin/main.ml`:

```ocaml
open Core
open Watsup

let run_watson () =
  let ic = Core_unix.open_process_in "watson report -dG" in
  let output = In_channel.input_all ic in
  let _ = Core_unix.close_process_in ic in
  output

let process_entries config entries =
  let worklogs = ref [] in
  let skipped = ref [] in
  let category = ref (match config.Config.category with
    | Some c -> c.selected
    | None -> "Development") in
  let config = ref config in

  let rec process_entry entry =
    let cached = Config.get_mapping !config entry.Watson.project in
    match cached with
    | Some Config.Skip ->
      skipped := (entry.project, entry.total) :: !skipped
    | Some Config.Auto_extract ->
      (* Extract tickets from tags *)
      let tickets = Ticket.extract_tickets (List.map entry.tags ~f:(fun t -> t.Watson.name)) in
      List.iter tickets ~f:(fun ticket ->
        let tag = List.find_exn entry.tags ~f:(fun t -> String.equal t.name ticket) in
        worklogs := {
          Worklog.ticket;
          duration = Duration.round_5min tag.duration;
          date = Date.today ~zone:Time_float.Zone.utc;
          category = !category;
          account = None;
          message = None;
          source = sprintf "%s:%s" entry.project ticket;
        } :: !worklogs)
    | _ ->
      let action = Prompt.prompt_entry entry ~cached ~category:!category in
      match action with
      | Prompt.Accept ticket ->
        config := Config.set_mapping !config entry.project (Config.Ticket ticket);
        worklogs := {
          Worklog.ticket;
          duration = Duration.round_5min entry.total;
          date = Date.today ~zone:Time_float.Zone.utc;
          category = !category;
          account = None;
          message = None;
          source = entry.project;
        } :: !worklogs
      | Prompt.Skip -> ()
      | Prompt.Skip_always ->
        config := Config.set_mapping !config entry.project Config.Skip;
        skipped := (entry.project, entry.total) :: !skipped
      | Prompt.Split ->
        List.iter entry.tags ~f:(fun tag ->
          let action = Prompt.prompt_tag ~project:entry.project tag in
          match action with
          | Prompt.Accept ticket ->
            worklogs := {
              Worklog.ticket;
              duration = Duration.round_5min tag.duration;
              date = Date.today ~zone:Time_float.Zone.utc;
              category = !category;
              account = None;
              message = None;
              source = sprintf "%s:%s" entry.project tag.name;
            } :: !worklogs
          | _ -> ())
      | Prompt.Change_category ->
        (* TODO: fetch categories and prompt *)
        process_entry entry
      | Prompt.Set_message _ ->
        (* TODO: handle message *)
        process_entry entry
      | Prompt.Quit ->
        raise_s [%message "User quit"]
  in

  List.iter entries ~f:process_entry;
  (List.rev !worklogs, List.rev !skipped, !config)

let main () =
  let config_path = Config.default_path () in
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  (* Check for token *)
  let config =
    if String.is_empty config.tempo_token then
      let token = Prompt.prompt_token () in
      { config with tempo_token = token }
    else
      config
  in

  (* Parse watson report *)
  let watson_output = run_watson () in
  let report = Watson.parse watson_output |> Or_error.ok_exn in

  printf "Watson report: %s\n" report.date_range;
  printf "Total entries: %d\n" (List.length report.entries);

  (* Process entries interactively *)
  let (worklogs, skipped, config) = process_entries config report.entries in

  (* Show summary and confirm *)
  if List.is_empty worklogs then begin
    printf "\nNo worklogs to post.\n";
  end else begin
    let manual = [] in  (* TODO: check accounts *)
    if Prompt.prompt_confirm_post worklogs ~skipped ~manual then begin
      (* TODO: Actually post to Tempo *)
      printf "\nPosting worklogs...\n";
      List.iter worklogs ~f:(fun w ->
        printf "  Posted %s (%s)\n" w.ticket (Duration.to_string w.duration))
    end else begin
      printf "\nAborted.\n"
    end
  end;

  (* Save config *)
  Config.save ~path:config_path config |> Or_error.ok_exn;
  printf "\nConfig saved to %s\n" config_path

let () = main ()
```

**Step 2: Build and test manually**

Run:
```bash
dune build
dune exec watsup
```

Expected: Runs and prompts for entries (or shows error if watson not installed)

**Step 3: Commit**

```bash
git add bin/main.ml
git commit -m "feat: implement main CLI entry point"
```

---

## Task 11: Implement Tempo API (Real HTTP Calls)

**Files:**
- Modify: `lib/tempo.ml`

**Step 1: Add HTTP client implementation**

Replace `lib/tempo.ml`:

```ocaml
open Core
open Lwt.Syntax
open Cohttp_lwt_unix

type category = {
  id : int;
  name : string;
} [@@deriving sexp]

type account = {
  id : int;
  name : string;
} [@@deriving sexp]

let base_url = "https://api.tempo.io/4"

let headers token =
  Cohttp.Header.of_list [
    ("Authorization", sprintf "Bearer %s" token);
    ("Content-Type", "application/json");
  ]

let fetch_categories ~token =
  let uri = Uri.of_string (base_url ^ "/work-attributes") in
  let* (resp, body) = Client.get ~headers:(headers token) uri in
  let* body_str = Cohttp_lwt.Body.to_string body in
  let status = Cohttp.Response.status resp in
  if Cohttp.Code.is_success (Cohttp.Code.code_of_status status) then
    try
      let json = Yojson.Safe.from_string body_str in
      let results = Yojson.Safe.Util.(json |> member "results" |> to_list) in
      let categories = List.filter_map results ~f:(fun item ->
        let open Yojson.Safe.Util in
        try
          let id = item |> member "id" |> to_int in
          let name = item |> member "name" |> to_string in
          Some { id; name }
        with _ -> None) in
      Lwt.return (Ok categories)
    with exn ->
      Lwt.return (Or_error.error_string (Exn.to_string exn))
  else
    Lwt.return (Or_error.error_string (sprintf "API error: %s" body_str))

let fetch_account_for_ticket ~token ~ticket =
  (* Tempo uses issue key to look up default account *)
  let uri = Uri.of_string (sprintf "%s/accounts/search?issueKey=%s" base_url ticket) in
  let* (resp, body) = Client.get ~headers:(headers token) uri in
  let* body_str = Cohttp_lwt.Body.to_string body in
  let status = Cohttp.Response.status resp in
  if Cohttp.Code.is_success (Cohttp.Code.code_of_status status) then
    try
      let json = Yojson.Safe.from_string body_str in
      let results = Yojson.Safe.Util.(json |> member "results" |> to_list) in
      match results with
      | [] -> Lwt.return (Ok None)
      | item :: _ ->
        let open Yojson.Safe.Util in
        let id = item |> member "id" |> to_int in
        let name = item |> member "name" |> to_string in
        Lwt.return (Ok (Some { id; name }))
    with exn ->
      Lwt.return (Or_error.error_string (Exn.to_string exn))
  else
    Lwt.return (Or_error.error_string (sprintf "API error: %s" body_str))

let post_worklog ~token worklog =
  let uri = Uri.of_string (base_url ^ "/worklogs") in
  let body_json = `Assoc [
    ("issueKey", `String worklog.Worklog.ticket);
    ("timeSpentSeconds", `Int (Duration.to_seconds worklog.duration));
    ("startDate", `String (Date.to_string worklog.date));
    ("startTime", `String "09:00:00");
    ("description", `String (Option.value worklog.message ~default:""));
    ("authorAccountId", `String "self");
  ] in
  let body = Cohttp_lwt.Body.of_string (Yojson.Safe.to_string body_json) in
  let* (resp, resp_body) = Client.post ~headers:(headers token) ~body uri in
  let* body_str = Cohttp_lwt.Body.to_string resp_body in
  let status = Cohttp.Response.status resp in
  if Cohttp.Code.is_success (Cohttp.Code.code_of_status status) then
    Lwt.return Worklog.Posted
  else if Cohttp.Code.code_of_status status = 401 then
    Lwt.return (Worklog.Failed "Unauthorized - check your API token")
  else
    Lwt.return (Worklog.Failed body_str)
```

**Step 2: Build to verify**

Run:
```bash
dune build
```

Expected: Builds successfully

**Step 3: Commit**

```bash
git add lib/tempo.ml
git commit -m "feat: implement real Tempo API calls"
```

---

## Task 12: Wire Up Lwt in Main

**Files:**
- Modify: `bin/main.ml`
- Modify: `bin/dune`

**Step 1: Add lwt to bin/dune**

Update `bin/dune`:

```dune
(executable
 (name main)
 (public_name watsup)
 (libraries watsup core core_unix lwt lwt.unix)
 (preprocess (pps ppx_jane)))
```

**Step 2: Update main.ml to use Lwt for posting**

Update the posting section in `bin/main.ml` to use Lwt:

```ocaml
(* Replace the posting section with: *)
    if Prompt.prompt_confirm_post worklogs ~skipped ~manual then begin
      printf "\nPosting worklogs...\n";
      Lwt_main.run (
        let open Lwt.Syntax in
        let* results = Lwt_list.map_s (fun w ->
          let* result = Tempo.post_worklog ~token:config.tempo_token w in
          let status = match result with
            | Worklog.Posted -> "done"
            | Worklog.Failed msg -> sprintf "FAILED: %s" msg
            | Worklog.Manual_required msg -> sprintf "MANUAL: %s" msg
          in
          printf "  %s (%s) - %s\n%!" w.ticket (Duration.to_string w.duration) status;
          Lwt.return result
        ) worklogs in
        let posted = List.count results ~f:(function Worklog.Posted -> true | _ -> false) in
        let failed = List.count results ~f:(function Worklog.Failed _ -> true | _ -> false) in
        printf "\nSummary: %d posted, %d failed\n" posted failed;
        Lwt.return ()
      )
    end
```

**Step 3: Build and test**

Run:
```bash
dune build
```

Expected: Builds successfully

**Step 4: Commit**

```bash
git add bin/main.ml bin/dune
git commit -m "feat: wire up Lwt for async Tempo API posting"
```

---

## Future Tasks (Not in MVP)

These are documented for later implementation:

- **Task 13:** Category selection with API fetch and caching
- **Task 14:** Account validation per ticket
- **Task 15:** Message input handling
- **Task 16:** Refresh keybinding for categories
- **Task 17:** Better error handling and retry logic
- **Task 18:** Command-line arguments (date range, dry-run mode)
