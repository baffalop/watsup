# UX Improvements Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Improve CLI usability by always showing context, offering change options for cached mappings, removing Auto_extract, using composite split-tag keys, teeing Watson output, and combining the summary.

**Architecture:** Changes are concentrated in `lib/main_logic.ml` (orchestration), `lib/config.ml` (remove Auto_extract variant), and `lib/processor.ml` (simplify split caching). The Io layer and Watson parser are unaffected. All prompt orchestration stays in `main_logic.ml`.

**Tech Stack:** OCaml 5.4, Core, ppx_expect (expect tests), Angstrom, effect handlers for IO.

**Testing:** This project uses expect tests. The workflow is: make changes → run `opam exec -- dune runtest` → review diff → `opam exec -- dune promote` → run tests again to verify. Never manually type expected output.

**Git:** Use simple `-m` strings or heredocs for commit messages. No command substitution (`$(cat ...)`).

---

### Task 1: Remove Auto_extract from Config

**Files:**
- Modify: `lib/config.ml:1-7` (mapping type + add backwards-compat sexp)
- Modify: `lib/config.mli:1-5` (mapping type)

**Step 1: Remove Auto_extract from config.mli**

Replace the mapping type:
```ocaml
type mapping =
  | Ticket of string
  | Skip
[@@deriving sexp]
```

**Step 2: Remove Auto_extract from config.ml and add backwards compat**

Replace the mapping type (lines 1-7):
```ocaml
type mapping =
  | Ticket of string
  | Skip
[@@deriving sexp]

(* Backwards compat: old configs may contain Auto_extract — treat as no mapping.
   This shadow must appear BEFORE the type t definition so t_of_sexp picks it up. *)
let mapping_of_sexp sexp =
  match sexp with
  | Sexp.Atom "Auto_extract" -> Skip
  | _ -> mapping_of_sexp sexp
```

Note: the shadowed `mapping_of_sexp` is placed between the `mapping` and `t` type definitions. The PPX-generated `t_of_sexp` will use the shadowed version, so old config files with `Auto_extract` entries load without error. Converting to `Skip` is acceptable — the user will be shown the skip mapping and can override it with `[t]`.

**Step 3: Run tests to see compile errors**

Run: `opam exec -- dune runtest`
Expected: compile errors in `processor.ml` referencing `Config.Auto_extract`. This is expected — we fix it in Task 2.

**Step 4: Commit**

```
git add lib/config.ml lib/config.mli
git commit -m "refactor: remove Auto_extract from Config.mapping type

Add backwards-compat sexp deserializer for old config files.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Remove Auto_extract handling from Processor

**Files:**
- Modify: `lib/processor.ml:20-79` (process_entry function)
- Modify: `lib/processor.ml:124-142, 174-212` (unit tests)

**Step 1: Update process_entry function**

In `process_entry` (line 20), remove the `| Some Config.Auto_extract ->` case (lines 32-45).

In the `| Split ->` case (lines 61-79), remove the auto_extract caching logic. Replace lines 74-78:
```ocaml
      (* No entry-level mapping for splits — per-tag mappings are handled by main_logic *)
      (decisions, None)
```

The `Split` case should become:
```ocaml
    | Split ->
      let decisions = List.filter_map entry.tags ~f:(fun tag ->
        match tag_prompt tag with
        | Tag_accept ticket ->
          let description = describe ticket in
          Some (Post {
            ticket;
            duration = Duration.round_5min tag.Watson.duration;
            source = sprintf "%s:%s" entry.project tag.name;
            description;
          })
        | Tag_skip -> None)
      in
      (decisions, None)
```

**Step 2: Remove Auto_extract unit tests**

Delete the test `"process_entry auto_extract"` (lines 124-142) and `"process_entry auto_extract with no ticket tags"` (lines 174-188).

**Step 3: Update split unit tests**

In `"process_entry split assigns per-tag"` (lines 190-212), update the expected mapping from `(Auto_extract)` to `()`:
```ocaml
  (* No entry-level mapping for splits *)
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| () |}]
```

**Step 4: Run tests, promote, verify**

Run: `opam exec -- dune runtest`
Then: `opam exec -- dune promote` (if expect output changed)
Then: `opam exec -- dune runtest` (verify clean)

**Step 5: Commit**

```
git add lib/processor.ml
git commit -m "refactor: remove Auto_extract handling from Processor

Splits no longer cache entry-level mappings. Per-tag composite key
caching will be handled by main_logic.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Watson report tee to stderr

**Files:**
- Modify: `lib/main_logic.ml:280-291` (run_day function)

**Step 1: Modify watson command and remove Report line**

In `run_day`, replace lines 282-290:
```ocaml
  let watson_cmd = sprintf "CLICOLOR_FORCE=1 watson report -G -f %s -t %s | tee /dev/stderr" date date in
  let watson_output = Io.run_command watson_cmd in
  let report = match Watson.parse watson_output with
    | Ok report -> report
    | Error err -> failwith @@ sprintf "Could not parse Watson output: %s" @@ Error.to_string_hum err
  in
```

Remove the `Io.output @@ sprintf "Report: %s (%d entries)\n"` line entirely. The raw Watson output is already displayed via the tee.

**Step 2: Update test helper to match new command**

In `test/test_e2e.ml`, the `start` helper's `run_cmd` function (line 39-43) matches commands by substring. The watson command now includes `CLICOLOR_FORCE=1` and `| tee /dev/stderr`, but the date substring is still present, so matching still works. No change needed to the helper.

**Step 3: Run e2e tests, promote, verify**

Run: `opam exec -- dune runtest`

Expected: all e2e tests will fail because they expect `Report: ...` lines that no longer exist. The new output will not include the `Report:` line.

Review the diffs carefully — the `Report:` line should simply be gone from all expected output.

Then: `opam exec -- dune promote`
Then: `opam exec -- dune runtest` (verify clean)

**Step 4: Commit**

```
git add lib/main_logic.ml test/test_e2e.ml
git commit -m "feat: tee Watson output to stderr for colored display

Replace Report summary line with raw Watson output via tee /dev/stderr.
CLICOLOR_FORCE=1 preserves colors when piped.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Always show entry context + cached/uncached prompts + auto-detect

This is the largest task. It refactors the entry prompting in `main_logic.ml`.

**Files:**
- Modify: `lib/main_logic.ml:143-176` (prompt functions)
- Modify: `lib/main_logic.ml:280-314` (run_day entry processing loop)
- Modify: `test/test_e2e.ml` (all e2e tests — expected output changes)

**Step 1: Replace prompt functions**

Replace `prompt_for_entry` (lines 143-162) with three functions:

```ocaml
let show_entry_context entry =
  let has_tags = not (List.is_empty entry.Watson.tags) in
  Io.output @@ sprintf "\n%s - %s"
    entry.project
    (Duration.to_string @@ Duration.round_5min entry.total);
  if has_tags then begin
    Io.output "\n";
    List.iter entry.tags ~f:(fun tag ->
      Io.output @@ sprintf "  [%-8s %s]\n" tag.Watson.name
        (Duration.to_string @@ Duration.round_5min tag.duration))
  end

type cached_response = Keep | Change_ticket | Change_category | Skip_once

let prompt_cached_entry ~ticket =
  Io.output @@ sprintf "  [-> %s]\n" ticket;
  Io.output "  [Enter] keep | [t] ticket | [c] category | [n] skip: ";
  match Io.input () with
  | "t" -> Change_ticket
  | "c" -> Change_category
  | "n" -> Skip_once
  | _ -> Keep

let prompt_cached_skip () =
  Io.output "  [skip]\n";
  Io.output "  [Enter] keep | [t] assign ticket: ";
  match Io.input () with
  | "t" -> Change_ticket
  | _ -> Keep

let prompt_uncached_entry entry =
  Io.output "\n";
  let has_tags = not (List.is_empty entry.Watson.tags) in
  let prompt_str = if has_tags
    then "  [ticket] assign all | [s] split by tags | [n] skip | [S] skip always: "
    else "  [ticket] assign | [n] skip | [S] skip always: "
  in
  Io.output prompt_str;
  let input = Io.input () in
  match input with
  | "n" -> Processor.Skip_once
  | "S" -> Processor.Skip_always
  | "s" when has_tags -> Processor.Split
  | ticket -> Processor.Accept ticket
```

Replace `prompt_for_tag` (lines 164-172) with:

```ocaml
let prompt_cached_tag tag ~ticket =
  Io.output @@ sprintf "  [%-8s %s] [-> %s] [Enter] keep | [t] change | [n] skip: "
    tag.Watson.name
    (Duration.to_string @@ Duration.round_5min tag.Watson.duration)
    ticket;
  match Io.input () with
  | "t" -> Change_ticket
  | "n" -> Skip_once
  | _ -> Keep

let prompt_uncached_tag ~project:_ tag =
  Io.output @@ sprintf "  [%-8s %s] [ticket] assign | [n] skip: "
    tag.Watson.name
    (Duration.to_string @@ Duration.round_5min tag.Watson.duration);
  let input = Io.input () in
  match input with
  | "n" -> Processor.Tag_skip
  | "" when Ticket.is_ticket_pattern tag.name -> Processor.Tag_accept tag.name
  | ticket -> Processor.Tag_accept ticket
```

Keep `prompt_description` unchanged.

**Step 2: Refactor entry processing in run_day**

Replace the entry processing fold (lines 292-313) with new logic. The key change: before calling `process_entry`, resolve the mapping and handle cached prompts.

```ocaml
  let all_decisions, config =
    List.fold report.entries ~init:([], config) ~f:(fun (acc_decisions, cfg) entry ->
      (* Resolve mapping: check cache, then auto-detect ticket pattern *)
      let cached = Config.get_mapping cfg entry.project in
      let cached = match cached with
        | Some _ -> cached
        | None when Ticket.is_ticket_pattern entry.project ->
          Some (Config.Ticket entry.project)
        | None -> None
      in

      (* Always show entry context *)
      show_entry_context entry;

      (* Handle cached vs uncached flow *)
      let decisions, cfg, force_category_change = match cached with
        | Some (Config.Ticket ticket) ->
          let response = prompt_cached_entry ~ticket in
          (match response with
           | Keep ->
             let description = prompt_description ticket in
             let decisions = [Processor.Post {
               ticket; duration = Duration.round_5min entry.total;
               source = entry.project; description;
             }] in
             let cfg = Config.set_mapping cfg entry.project (Config.Ticket ticket) in
             (decisions, cfg, false)
           | Change_ticket ->
             let decisions, new_mapping = Processor.process_entry
               ~entry ~cached:None
               ~prompt:prompt_uncached_entry
               ~tag_prompt:(prompt_uncached_tag ~project:entry.project)
               ~describe:prompt_description
               () in
             let cfg = Option.value_map new_mapping ~default:cfg
               ~f:(fun m -> Config.set_mapping cfg entry.project m) in
             (decisions, cfg, false)
           | Change_category ->
             let description = prompt_description ticket in
             let decisions = [Processor.Post {
               ticket; duration = Duration.round_5min entry.total;
               source = entry.project; description;
             }] in
             let cfg = Config.set_mapping cfg entry.project (Config.Ticket ticket) in
             (decisions, cfg, true)
           | Skip_once -> ([], cfg, false))
        | Some Config.Skip ->
          let response = prompt_cached_skip () in
          (match response with
           | Change_ticket ->
             let decisions, new_mapping = Processor.process_entry
               ~entry ~cached:None
               ~prompt:prompt_uncached_entry
               ~tag_prompt:(prompt_uncached_tag ~project:entry.project)
               ~describe:prompt_description
               () in
             let cfg = Option.value_map new_mapping ~default:cfg
               ~f:(fun m -> Config.set_mapping cfg entry.project m) in
             (decisions, cfg, false)
           | Keep | _ ->
             let decisions = [Processor.Skip {
               project = entry.project; duration = entry.total;
             }] in
             (decisions, cfg, false))
        | None ->
          let decisions, new_mapping = Processor.process_entry
            ~entry ~cached:None
            ~prompt:prompt_uncached_entry
            ~tag_prompt:(prompt_uncached_tag ~project:entry.project)
            ~describe:prompt_description
            () in
          let cfg = Option.value_map new_mapping ~default:cfg
            ~f:(fun m -> Config.set_mapping cfg entry.project m) in
          (decisions, cfg, false)
      in

      (* Category prompting for each Post decision *)
      let cfg = match cfg.categories with
        | Some { options; _ } when not (String.is_empty cfg.tempo_category_attr_key)
            && not (List.is_empty options) ->
          List.fold decisions ~init:cfg ~f:(fun c -> function
            | Processor.Post { ticket; _ } ->
              if force_category_change then begin
                Io.output @@ sprintf "  %s category:\n" ticket;
                let value = prompt_category_list ~options ~current_value:None in
                Config.set_category_selection c ticket value
              end else
                prompt_category ~config:c ~options ticket
            | Processor.Skip _ -> c)
        | _ -> cfg
      in
      (List.rev_append decisions acc_decisions, cfg))
  in
  let all_decisions = List.rev all_decisions in
```

**Step 3: Handle split with composite keys in process_entry callback**

For now, the `prompt_uncached_entry` function can return `Split`, which passes through to `process_entry`'s Split handling. The tag_prompt callback (`prompt_uncached_tag`) handles per-tag prompting. Composite key caching is Task 5.

**Step 4: Run e2e tests, promote, verify**

Run: `opam exec -- dune runtest`

All e2e tests will fail due to changed output format. Review diffs carefully:
- Entry context now always shows project/tags/duration
- Cached entries show `[-> TICKET]` + keep/change/skip prompt
- Auto-detected ticket patterns show same cached flow
- Uncached entries show same prompt but context is separated

Then: `opam exec -- dune promote`
Then: `opam exec -- dune runtest` (verify clean)

**Step 5: Commit**

```
git add lib/main_logic.ml test/test_e2e.ml
git commit -m "feat: always show entry context, add cached entry prompts

Cached entries now show project/tags/duration and offer keep/change
ticket/category/skip. Auto-detect ticket patterns in project names.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 5: Composite keys for split tags

**Files:**
- Modify: `lib/main_logic.ml` (split handling in run_day)
- Modify: `test/test_e2e.ml` (add composite key test)

**Step 1: Modify split tag handling**

The split flow currently goes through `Processor.process_entry` with a `tag_prompt` callback. We need to intercept the split flow to handle composite key caching and cached tag prompts.

When `prompt_uncached_entry` returns `Processor.Split`, instead of passing through to `process_entry`'s Split handling, handle it directly in `main_logic.ml`:

In the `| None ->` branch of the entry processing, when `process_entry` would handle a Split, we need to handle it ourselves. The cleanest approach: check for Split before calling process_entry.

Replace the `| None ->` branch:
```ocaml
        | None ->
          Io.output "\n";
          let has_tags = not (List.is_empty entry.Watson.tags) in
          let prompt_str = if has_tags
            then "  [ticket] assign all | [s] split by tags | [n] skip | [S] skip always: "
            else "  [ticket] assign | [n] skip | [S] skip always: "
          in
          Io.output prompt_str;
          let input = Io.input () in
          (match input with
           | "s" when has_tags ->
             (* Split: handle per-tag with composite keys *)
             let decisions = List.filter_map entry.tags ~f:(fun tag ->
               let composite_key = sprintf "%s:%s" entry.project tag.Watson.name in
               let tag_cached = Config.get_mapping cfg composite_key in
               let tag_cached = match tag_cached with
                 | Some _ -> tag_cached
                 | None when Ticket.is_ticket_pattern tag.name ->
                   Some (Config.Ticket tag.name)
                 | None -> None
               in
               match tag_cached with
               | Some (Config.Ticket ticket) ->
                 let response = prompt_cached_tag tag ~ticket in
                 (match response with
                  | Keep ->
                    let description = prompt_description ticket in
                    cfg := Config.set_mapping !cfg composite_key (Config.Ticket ticket);
                    Some (Processor.Post {
                      ticket; duration = Duration.round_5min tag.Watson.duration;
                      source = sprintf "%s:%s" entry.project tag.name; description;
                    })
                  | Change_ticket ->
                    let resp = prompt_uncached_tag ~project:entry.project tag in
                    (match resp with
                     | Processor.Tag_accept ticket ->
                       let description = prompt_description ticket in
                       cfg := Config.set_mapping !cfg composite_key (Config.Ticket ticket);
                       Some (Processor.Post {
                         ticket; duration = Duration.round_5min tag.Watson.duration;
                         source = sprintf "%s:%s" entry.project tag.name; description;
                       })
                     | Processor.Tag_skip -> None)
                  | Skip_once -> None
                  | Change_category -> (* treat as Keep for tags, category handled later *)
                    let description = prompt_description ticket in
                    cfg := Config.set_mapping !cfg composite_key (Config.Ticket ticket);
                    Some (Processor.Post {
                      ticket; duration = Duration.round_5min tag.Watson.duration;
                      source = sprintf "%s:%s" entry.project tag.name; description;
                    }))
               | Some Config.Skip -> None
               | None ->
                 let resp = prompt_uncached_tag ~project:entry.project tag in
                 (match resp with
                  | Processor.Tag_accept ticket ->
                    let description = prompt_description ticket in
                    cfg := Config.set_mapping !cfg composite_key (Config.Ticket ticket);
                    Some (Processor.Post {
                      ticket; duration = Duration.round_5min tag.Watson.duration;
                      source = sprintf "%s:%s" entry.project tag.name; description;
                    })
                  | Processor.Tag_skip -> None))
             in
             (decisions, !cfg, false)
           | "n" -> ([], cfg, false)
           | "S" ->
             let decisions = [Processor.Skip {
               project = entry.project; duration = entry.total;
             }] in
             let cfg = Config.set_mapping cfg entry.project Config.Skip in
             (decisions, cfg, false)
           | ticket ->
             let description = prompt_description ticket in
             let decisions = [Processor.Post {
               ticket; duration = Duration.round_5min entry.total;
               source = entry.project; description;
             }] in
             let cfg = Config.set_mapping cfg entry.project (Config.Ticket ticket) in
             (decisions, cfg, false))
```

**Important:** The split handling above uses a mutable ref for config (`cfg := ...`) because we need to accumulate config changes across multiple tags within the fold. Alternatively, use a nested fold over tags. The nested fold approach is cleaner (avoids mutation):

```ocaml
           | "s" when has_tags ->
             let decisions, cfg = List.fold entry.tags ~init:([], cfg)
               ~f:(fun (acc, cfg) tag ->
                 let composite_key = sprintf "%s:%s" entry.project tag.Watson.name in
                 let tag_cached = Config.get_mapping cfg composite_key in
                 let tag_cached = match tag_cached with
                   | Some _ -> tag_cached
                   | None when Ticket.is_ticket_pattern tag.name ->
                     Some (Config.Ticket tag.name)
                   | None -> None
                 in
                 match tag_cached with
                 | Some (Config.Ticket ticket) ->
                   let response = prompt_cached_tag tag ~ticket in
                   (match response with
                    | Keep | Change_category ->
                      let description = prompt_description ticket in
                      let cfg = Config.set_mapping cfg composite_key (Config.Ticket ticket) in
                      (Processor.Post {
                        ticket; duration = Duration.round_5min tag.Watson.duration;
                        source = sprintf "%s:%s" entry.project tag.name; description;
                      } :: acc, cfg)
                    | Change_ticket ->
                      (match prompt_uncached_tag ~project:entry.project tag with
                       | Processor.Tag_accept ticket ->
                         let description = prompt_description ticket in
                         let cfg = Config.set_mapping cfg composite_key (Config.Ticket ticket) in
                         (Processor.Post {
                           ticket; duration = Duration.round_5min tag.Watson.duration;
                           source = sprintf "%s:%s" entry.project tag.name; description;
                         } :: acc, cfg)
                       | Processor.Tag_skip -> (acc, cfg))
                    | Skip_once -> (acc, cfg))
                 | Some Config.Skip -> (acc, cfg)
                 | None ->
                   (match prompt_uncached_tag ~project:entry.project tag with
                    | Processor.Tag_accept ticket ->
                      let description = prompt_description ticket in
                      let cfg = Config.set_mapping cfg composite_key (Config.Ticket ticket) in
                      (Processor.Post {
                        ticket; duration = Duration.round_5min tag.Watson.duration;
                        source = sprintf "%s:%s" entry.project tag.name; description;
                      } :: acc, cfg)
                    | Processor.Tag_skip -> (acc, cfg)))
             in
             (List.rev decisions, cfg, false)
```

Use this nested fold version (no mutation).

**Step 2: Write e2e test for composite key isolation**

Add to `test/test_e2e.ml`:

```ocaml
let%expect_test "composite key: split tag mapping doesn't apply to standalone project" =
  with_temp_config @@ fun ~config_path ->
    (* cr:review mapped to REVIEW-55 from a previous split *)
    let config = {
      (test_config_with_mappings [
        ("cr:review", Config.Ticket "REVIEW-55");
      ]) with
      category_selections = [("REVIEW-55", "dev")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    (* Day has standalone "review" project — should NOT use cr:review mapping *)
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

review - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* review should appear as uncached — no composite key match *)
    [%expect {||}];
    (* Expect uncached prompt (not cached REVIEW-55) *)
    ...
```

Write the test with empty `[%expect]` blocks, run tests, review output, promote.

**Step 3: Run e2e tests, promote, verify**

Run: `opam exec -- dune runtest`
Then: `opam exec -- dune promote`
Then: `opam exec -- dune runtest`

**Step 4: Commit**

```
git add lib/main_logic.ml test/test_e2e.ml
git commit -m "feat: composite keys for split tag mappings

Split tags cache as 'project:tag' keys. Standalone projects use plain
keys. Prevents cross-contamination between split tags and projects.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Combined summary

**Files:**
- Modify: `lib/main_logic.ml:317-345` (summary section)

**Step 1: Replace summary and worklogs sections**

Replace the Summary + Worklogs to Post sections (lines 317-346) with a single combined summary:

```ocaml
  (* Combined Summary *)
  Io.output "\n=== Summary ===\n";
  let posts, skips = List.partition_tf all_decisions ~f:(function
    | Processor.Post _ -> true
    | Processor.Skip _ -> false) in

  let cat_options = match config.categories with
    | Some { options; _ } -> options | None -> [] in

  if not (List.is_empty posts) then begin
    Io.output "Post:\n";
    List.iter posts ~f:(function
      | Processor.Post { ticket; duration; source; description } ->
        let cat_str = match resolve_category_for_display ~config ~options:cat_options ticket with
          | Some cat -> sprintf "  [%s]" (Category.name cat) | None -> "" in
        let desc_str = if String.is_empty description then ""
          else sprintf "  \"%s\"" description in
        Io.output @@ sprintf "  %-10s (%s)%s  %s%s\n" ticket
          (Duration.to_string duration) cat_str source desc_str
      | Processor.Skip _ -> ())
  end;

  if not (List.is_empty skips) then begin
    Io.output "Skip:\n";
    List.iter skips ~f:(function
      | Processor.Skip { project; duration } ->
        Io.output @@ sprintf "  %-10s (%s)\n" project (Duration.to_string duration)
      | Processor.Post _ -> ())
  end;
```

Remove the separate `=== Worklogs to Post ===` section entirely. The confirmation prompt (`[Enter] post | [n] skip day:`) stays, placed directly after the combined summary.

**Step 2: Run e2e tests, promote, verify**

Run: `opam exec -- dune runtest`
Then: `opam exec -- dune promote`
Then: `opam exec -- dune runtest`

**Step 3: Commit**

```
git add lib/main_logic.ml test/test_e2e.ml
git commit -m "feat: combine Summary and Worklogs into single summary

Grouped by Post/Skip. Each post line shows ticket, duration, category,
source, and description.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 7: New E2E tests for new behaviors

**Files:**
- Modify: `test/test_e2e.ml`

Write new e2e tests with empty `[%expect]` blocks, run, review output, promote.

**Step 1: Test cached entry keep flow**

```ocaml
let%expect_test "cached ticket: keep all" =
  with_temp_config @@ fun ~config_path ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      category_selections = [("PROJ-123", "dev")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    ...
```

**Step 2: Test cached entry change ticket**

```ocaml
let%expect_test "cached ticket: change ticket" =
  ...
```

**Step 3: Test auto-detect ticket pattern in project name**

```ocaml
let%expect_test "auto-detect: project name is ticket pattern" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

DEV-123 - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Should auto-detect DEV-123 and show cached prompt *)
    ...
```

**Step 4: Test cached skip override**

```ocaml
let%expect_test "cached skip: override with ticket" =
  ...
```

**Step 5: Test composite key isolation (split tag vs standalone project)**

Already outlined in Task 5. Ensure the test verifies that a `cr:review` mapping does NOT apply to standalone `review`.

**Step 6: Run, promote, verify**

Run: `opam exec -- dune runtest`
Review all diffs carefully.
Then: `opam exec -- dune promote`
Then: `opam exec -- dune runtest`

**Step 7: Commit**

```
git add test/test_e2e.ml
git commit -m "test: add e2e tests for cached prompts, auto-detect, composite keys

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 8: Final verification

**Step 1: Run full test suite**

Run: `opam exec -- dune runtest`
Expected: all tests pass.

**Step 2: Manual smoke test**

Run: `./scripts/test-cli.sh`
Verify:
- Watson output appears with colors before prompts
- Cached entries show context and offer keep/change
- Split tags use per-tag prompts with auto-detection
- Summary is combined into one section
- Description is always prompted

**Step 3: Commit any final fixes**
