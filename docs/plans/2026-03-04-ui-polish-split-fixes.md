# UI Polish and Split Flow Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix colour inconsistencies (`{tag}` conflicts with `{action}`, new `{key}` tag, consistent `{prompt}` usage), fix category prompts appearing out-of-order in split flow, and add probing E2E tests to expose and fix split tag mapping persistence bugs.

**Architecture:** Four independent areas: (1) `io.ml` colour system, (2) `prompt.ml` styling, (3) `main_logic.ml` split category ordering, (4) new E2E tests for split mapping round-trips.

**Tech Stack:** OCaml 5.4, Core, ppx_expect. Build: `opam exec -- dune runtest`. Promote: `opam exec -- dune promote`.

---

## Background

### Colour system (`io.ml`)

Tags map to ANSI colours via `color_of_tag`. Currently `{tag}` and `{action}` both map to `Blue` — a conflict. The `{tag}` tag is used for Watson tag names (e.g. `[DEV-101 33m]`). The `{action}` tag is used for decision labels (`[-> PROJ-123 "task"]`, `[Enter] keep`, etc.). They must be visually distinct.

Fix: add `Magenta` colour and map `{tag}` to it.

New `{key}` tag needed for inline ticket/project data inside prompt strings (e.g. `Description for PROJ-123 (optional):`). The surrounding text uses `{prompt}` = `Dim`; `{key}` = `Bold` makes the data part stand out.

### Prompt styling (`prompt.ml`)

`description` (line 66) uses `Io.output` — no colour at all. Should use `{prompt}` for instructional text and `{key}` for the ticket data.

`category` prompt lines use `Io.output` or partial `{prompt}` tagging, inconsistently.

### Category prompt ordering in split flow (`main_logic.ml`)

`run_day` processes each Watson entry in a `List.fold`. For each entry it calls the appropriate handler (e.g. `handle_split_tags`), which gathers decisions. Then, AFTER the handler returns, a second pass prompts for categories for all decisions.

For split entries this is wrong: the flow becomes ticket→desc for tag1, ticket→desc for tag2, **then** category for tag1, category for tag2. The user wants: ticket→desc→category per tag.

Fix: `handle_split_tags`'s inner `accept_tag` function handles the category prompt immediately after the description. Outer loop is then told to skip category prompting for that entry. This requires changing the `force_category_change : bool` signal into a three-way `category_handling` type.

### Split mapping persistence (`main_logic.ml` / `test_e2e.ml`)

The user reports new mappings may not save correctly on split tags when a previous mapping already exists. Adding probing E2E tests will expose the failure; the fix follows.

---

## Task 1: Add `Magenta` colour and `{key}` tag to `io.ml`

**Files:**
- Modify: `lib/io.ml`

**Step 1: Add `Magenta` to the colour type and ANSI table**

In `lib/io.ml`, change:
```ocaml
type color = Reset | Bold | Dim | Red | Green | Yellow | Blue | Cyan
```
to:
```ocaml
type color = Reset | Bold | Dim | Red | Green | Yellow | Blue | Cyan | Magenta
```

Add to `ansi_code_of_color`:
```ocaml
  | Magenta -> "\027[35m"
```

**Step 2: Change `{tag}` to Magenta, add `{key}` = Bold**

In `color_of_tag`, change:
```ocaml
  | "tag" -> Some Blue
```
to:
```ocaml
  | "tag" -> Some Magenta
  | "key" -> Some Bold
```

**Step 3: Update `run_styled` helper in `io.ml` tests**

In `run_styled` (the test helper at line 222), add the Magenta case:
```ocaml
  let tag = match c with
    | Reset -> "/)" | Bold -> "(B" | Dim -> "(D" | Red -> "(R"
    | Green -> "(G" | Yellow -> "(Y" | Blue -> "(U" | Cyan -> "(C"
    | Magenta -> "(M"
  in
```

**Step 4: Add a `{key}` tag test and run to get proposed output**

Add after the existing `styled` tests in `io.ml`:
```ocaml
let%expect_test "styled: key tag" =
  run_styled "{key}PROJ-123{/} done";
  [%expect {||}]
```

Run: `opam exec -- dune runtest 2>&1 | head -40`
Expected: FAIL with proposed output showing `(BPROJ-123/) done`

**Step 5: Promote and verify**

```bash
opam exec -- dune promote
opam exec -- dune runtest
```
Expected: PASS

---

## Task 2: Update `display_watson_report` test in `main_logic.ml` for `{tag}` → Magenta

**Files:**
- Modify: `lib/main_logic.ml`

The existing `display_watson_report` test (around line 71) expects `(U` (Blue) for `{tag}`. After Task 1, `{tag}` is Magenta = `(M`.

**Step 1: Run tests to see the failure**

```bash
opam exec -- dune runtest 2>&1 | grep -A 20 "display_watson_report"
```
Expected: FAIL — `(UDEV-101` vs expected `(MDEV-101`

**Step 2: Promote**

```bash
opam exec -- dune promote
opam exec -- dune runtest
```
Expected: PASS

---

## Task 3: Apply `{prompt}` + `{key}` consistently in `prompt.ml`

**Files:**
- Modify: `lib/prompt.ml`

**Step 1: Fix `description` function (line 66)**

Change:
```ocaml
let description ticket =
  Io.output @@ sprintf "  Description for %s (optional): " (Ticket.Key.to_string ticket);
  Io.input ()
```
to:
```ocaml
let description ticket =
  Io.styled @@ sprintf "  {prompt}Description for{/} {key}%s{/} {prompt}(optional):{/} "
    (Ticket.Key.to_string ticket);
  Io.input ()
```

**Step 2: Fix `category` function — no-cache case (around line 102)**

Change:
```ocaml
  | None ->
    Io.output @@ sprintf "  %s category:\n" ticket_str;
    let value = category_list ~options ~current_value:None in
    Config.set_category_selection config ticket value)
```
to:
```ocaml
  | None ->
    Io.styled @@ sprintf "  {key}%s{/} {prompt}category:{/}\n" ticket_str;
    let value = category_list ~options ~current_value:None in
    Config.set_category_selection config ticket value)
```

**Step 3: Fix `category` function — cached keep/change case (around line 90)**

Change:
```ocaml
     | Some cat ->
       Io.styled @@ sprintf "  %s category: %s\n    {prompt}[Enter] keep | [c] change:{/} " ticket_str (Category.name cat);
```
to:
```ocaml
     | Some cat ->
       Io.styled @@ sprintf "  {key}%s{/} {prompt}category: %s\n    [Enter] keep | [c] change:{/} "
         ticket_str (Category.name cat);
```

**Step 4: Fix `category` function — obsolete selection case (around line 98)**

Change:
```ocaml
     | None ->
       Io.output @@ sprintf "  %s category (previous selection no longer available):\n" ticket_str;
```
to:
```ocaml
     | None ->
       Io.styled @@ sprintf "  {key}%s{/} {prompt}category (previous selection no longer available):{/}\n" ticket_str;
```

**Step 5: Run tests — expect failures in E2E tests that match description/category output**

```bash
opam exec -- dune runtest 2>&1 | head -80
```

The E2E tests compare exact output. Prompt text has changed. Check what the new output looks like.

**Step 6: Promote and verify**

```bash
opam exec -- dune promote
opam exec -- dune runtest
```
Expected: PASS

---

## Task 4: Fix category prompt ordering in split flow (`main_logic.ml`)

**Files:**
- Modify: `lib/main_logic.ml`

### Background

Currently `run_day` returns `(decisions, cfg, force_category_change : bool)` from each entry handler. After the handler, it loops over decisions and prompts for categories. For split entries, all tag tickets and descriptions are collected first, then all categories appear at the end — wrong order.

The fix: `handle_split_tags`'s `accept_tag` helper prompts for category inline. The outer loop is told to skip category prompting for that entry. Use a three-way type instead of `bool`.

**Step 1: Add `category_handling` type at top of `run_day`**

At the start of `run_day` (before `handle_split_tags`), add a local type:
```ocaml
  let module Cat = struct
    type t = Normal | Force_fresh | Skip_all
  end in
```

Or simpler — use a variant directly in the function. Actually since it's used in local pattern matches only, just define it as a type alias at the module level (before `run_day`) for clarity. Add before `run_day`:

```ocaml
type category_handling = Normal | Force_fresh | Skip_all
```

**Step 2: Update `handle_split_tags` return type and add inline category prompting**

The function currently ends with:
```ocaml
    (List.rev decisions, cfg, false)
```
and `accept_tag` is:
```ocaml
    let accept_tag acc cfg composite_key tag (ticket : Ticket.Key.t) =
      let description = Prompt.description ticket in
      let cfg = Config.set_mapping cfg composite_key (Config.Ticket ticket) in
      (Processor.Post {
        ticket; duration = Duration.round_5min tag.Watson.duration;
        source = sprintf "%s:%s" entry.Watson.project tag.Watson.name; description;
      } :: acc, cfg)
    in
```

Change `accept_tag` to also prompt for category:
```ocaml
    let accept_tag acc cfg composite_key tag (ticket : Ticket.Key.t) =
      let description = Prompt.description ticket in
      let cfg = Config.set_mapping cfg composite_key (Config.Ticket ticket) in
      let cfg = match cfg.categories with
        | Some { options; _ } when not (String.is_empty cfg.tempo_category_attr_key)
            && not (List.is_empty options) ->
          Prompt.category ~config:cfg ~options ticket
        | _ -> cfg
      in
      (Processor.Post {
        ticket; duration = Duration.round_5min tag.Watson.duration;
        source = sprintf "%s:%s" entry.Watson.project tag.Watson.name; description;
      } :: acc, cfg)
    in
```

Change the return at the end of `handle_split_tags`:
```ocaml
    (List.rev decisions, cfg, Skip_all)
```

**Step 3: Update all other inner functions to return `category_handling`**

`handle_cached_entry` currently returns `(decisions, cfg, force_category_change : bool)`. Change each arm:
- `Keep` → return `(decisions, cfg, Normal)`
- `Split` → already calls `handle_split_tags` which returns `Skip_all`; no change needed in the arm itself
- `Change_ticket` paths → return `Normal` (from whatever `run_uncached` returns)
- `Change_category` → return `(decisions, cfg, Force_fresh)`
- `Skip_once` → return `([], cfg, Normal)`

Similarly `run_uncached` always returns `Normal`:
- All arms: change `false` to `Normal`

`Project_skip` arms in the main dispatch:
- The `(decisions, cfg, false)` → `(decisions, cfg, Normal)`

**Step 4: Update the outer category loop to use `category_handling`**

Change:
```ocaml
      (* Category prompting for each Post decision *)
      let cfg = match cfg.categories with
        | Some { options; _ } when not (String.is_empty cfg.tempo_category_attr_key)
            && not (List.is_empty options) ->
          List.fold decisions ~init:cfg ~f:(fun c -> function
            | Processor.Post { ticket; _ } ->
              if force_category_change then begin
                Io.output @@ sprintf "  %s category:\n" (Ticket.Key.to_string ticket);
                let value = Prompt.category_list ~options ~current_value:None in
                Config.set_category_selection c ticket value
              end else
                Prompt.category ~config:c ~options ticket
            | Processor.Skip _ -> c)
        | _ -> cfg
      in
```
to:
```ocaml
      (* Category prompting for each Post decision *)
      let cfg = match category_handling, cfg.categories with
        | Skip_all, _ -> cfg  (* handled inline in handle_split_tags *)
        | _, Some { options; _ } when not (String.is_empty cfg.tempo_category_attr_key)
            && not (List.is_empty options) ->
          List.fold decisions ~init:cfg ~f:(fun c -> function
            | Processor.Post { ticket; _ } ->
              (match category_handling with
               | Force_fresh ->
                 Io.styled @@ sprintf "  {key}%s{/} {prompt}category:{/}\n" (Ticket.Key.to_string ticket);
                 let value = Prompt.category_list ~options ~current_value:None in
                 Config.set_category_selection c ticket value
               | Normal | Skip_all ->
                 Prompt.category ~config:c ~options ticket)
            | Processor.Skip _ -> c)
        | _, _ -> cfg
      in
```

Note: rename `force_category_change` to `category_handling` in the destructuring of the handler return.

**Step 5: Run tests — expect E2E test failures because category prompts now appear inline**

```bash
opam exec -- dune runtest 2>&1 | head -100
```

The existing E2E tests for split flows ("comprehensive interactive flow", "split by tags: full and partial", "cached mappings: ticket and skip (cr uncached)") have category prompts at the END of all tag prompts. After this fix, categories will appear immediately after each tag's description. The tests will fail with mismatched ordering.

**Step 6: Promote to capture new ordering**

```bash
opam exec -- dune promote
opam exec -- dune runtest
```
Expected: PASS

**Step 7: Manually review the promoted output**

Read the promoted expect blocks and verify the ordering is now:
- tag1: ticket → description → category
- tag2: ticket → description → category

---

## Task 5: Add probing E2E tests for split mapping persistence

**Files:**
- Modify: `test/test_e2e.ml`

These tests probe scenarios involving split tags when a previous mapping exists. They are written with EMPTY expect blocks first to capture actual behaviour, then the behaviour is examined and any bug fixed.

**Step 1: Add test "split mappings persist across runs"**

This tests that composite key mappings from a first split run are used as cached prompts in the second run.

Add to `test_e2e.ml`:
```ocaml
let%expect_test "split mappings persist across runs" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 1h 20m 00s
	[DEV-101     40m 00s]
	[DEV-202     40m 00s]

Total: 1h 20m 00s|} in
    (* Run 1: auto-split, keep both *)
    let t1 = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {||}];
    (* DEV-101: auto-inferred, cached_tag prompt *)
    http_get t1 (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {||}];
    input t1 "";   (* keep *)
    [%expect {||}];
    input t1 "";   (* description *)
    [%expect {||}];
    input t1 "1";  (* category: Development *)
    (* DEV-202: auto-inferred, cached_tag prompt *)
    http_get t1 (jira_issue_response ~key:"DEV-202" ~summary:"Dev task 202" ~id:202);
    [%expect {||}];
    input t1 "";   (* keep *)
    [%expect {||}];
    input t1 "";   (* description *)
    [%expect {||}];
    input t1 "1";  (* category: Development *)
    (* Summary + skip day *)
    [%expect {||}];
    input t1 "n";
    [%expect {||}];
    finish t1;
    (* Run 2: mappings should be saved as composite keys -> auto-split with cached prompts *)
    let t2 = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {||}];
    (* Both DEV-101 and DEV-202 should appear as cached (composite keys in config) *)
    http_get t2 (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {||}];
    input t2 "";
    [%expect {||}];
    input t2 "";
    [%expect {||}];
    input t2 "1";
    http_get t2 (jira_issue_response ~key:"DEV-202" ~summary:"Dev task 202" ~id:202);
    [%expect {||}];
    input t2 "";
    [%expect {||}];
    input t2 "";
    [%expect {||}];
    input t2 "1";
    [%expect {||}];
    input t2 "n";
    [%expect {||}];
    finish t2
```

**Step 2: Add test "split after project-level mapping: composite keys saved, project key cleared"**

```ocaml
let%expect_test "split after project-level mapping: clears project key, saves composite" =
  with_temp_config @@ fun ~config_path ->
    (* Config has a project-level mapping cr -> PROJ-1 from a previous non-split run *)
    let config = test_config_with_mappings
      [("cr", Config.Ticket (Ticket.Key.of_string_exn "PROJ-1"))] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 1h 20m 00s
	[DEV-101     40m 00s]
	[DEV-202     40m 00s]

Total: 1h 20m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* cr: cached ticket prompt — lookup PROJ-1 first *)
    [%expect {||}];
    http_get t (jira_issue_response ~key:"PROJ-1" ~summary:"Project one" ~id:11);
    [%expect {||}];
    input t "s";   (* split *)
    (* DEV-101: auto-inferred *)
    [%expect {||}];
    http_get t (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {||}];
    input t "";   (* keep *)
    [%expect {||}];
    input t "";   (* description *)
    [%expect {||}];
    input t "1";  (* category *)
    (* DEV-202: auto-inferred *)
    [%expect {||}];
    http_get t (jira_issue_response ~key:"DEV-202" ~summary:"Dev task 202" ~id:202);
    [%expect {||}];
    input t "";   (* keep *)
    [%expect {||}];
    input t "";   (* description *)
    [%expect {||}];
    input t "1";  (* category *)
    [%expect {||}];
    input t "n";
    [%expect {||}];
    finish t;
    (* Verify: config should have cr:DEV-101 and cr:DEV-202 but NOT cr *)
    let saved = Config.load ~path:config_path |> Or_error.ok_exn in
    let has_cr = Option.is_some (Config.get_mapping saved "cr") in
    let has_cr_dev101 = Option.is_some (Config.get_mapping saved "cr:DEV-101") in
    let has_cr_dev202 = Option.is_some (Config.get_mapping saved "cr:DEV-202") in
    printf "cr: %b, cr:DEV-101: %b, cr:DEV-202: %b\n" has_cr has_cr_dev101 has_cr_dev202;
    [%expect {||}]
```

**Step 3: Run tests to see actual output**

```bash
opam exec -- dune runtest 2>&1 | tail -60
```

The empty expect blocks will show proposed output (actual behaviour). Examine:
- Does run 2 in "split mappings persist" show the cached auto-split prompts (Good) or the uncached prompt (Bad)?
- In "split after project-level mapping", does the `printf` show `cr: false, cr:DEV-101: true, cr:DEV-202: true` (Good) or something else (Bad)?

**Step 4: Fix any bugs found**

Based on test output:

*If split mappings don't persist (Test 1 run 2 shows uncached prompt):*
- Likely `handle_split_tags` is not saving composite keys to config. Check that `accept_tag` is using the `cfg` accumulator correctly through the fold (it does via the fold's `(acc, cfg)` tuple). Check if the final `cfg` is returned correctly from `handle_split_tags`.

*If project-level cr mapping persists (Test 2 printf shows `cr: true`):*
- `handle_split_tags`'s cleanup at end removes `entry.Watson.project` = `"cr"`. Check this actually runs when split is triggered from `handle_cached_entry`. The `entry.Watson.project` access in `handle_split_tags` uses the `entry` from the closure — verify it's `entry.Watson.project` not `entry.project` (would be a type error, but check).

*If categories appear in wrong order in existing tests after Task 4:*
- Covered by Task 4 promote step.

**Step 5: Promote final state and verify all pass**

```bash
opam exec -- dune promote
opam exec -- dune runtest
```
Expected: all tests PASS.

**Step 6: Commit**

```bash
git add lib/io.ml lib/main_logic.ml lib/prompt.ml test/test_e2e.ml
git commit -m "fix: colour polish, inline split categories, split mapping e2e tests"
```

---

## Notes

- The `{key}` tag in `prompt.ml` category prompts for `Force_fresh` case (in `main_logic.ml` Task 4 Step 4) replaces the existing `Io.output @@ sprintf "  %s category:\n"`. These are now done in `accept_tag` inside `handle_split_tags` (via `Prompt.category`), so the `Force_fresh` path in the outer loop is only reached for non-split entries where the user explicitly chose `[c] change category`. Double-check this path is exercised by the "category selection and override" E2E test.

- All E2E tests suppress colour output (the `start` helper discards `Set_color` effects), so colour changes in Tasks 1-3 don't affect E2E tests — only the unit tests in `io.ml` and `main_logic.ml` need promotion.

- `prompt.ml` has no inline expect tests, so changes there are validated entirely through E2E tests.
