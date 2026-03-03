# E2E Test Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restructure e2e tests from 14 overlapping tests to 10 focused tests, adding first-run credential flow, config round-trip persistence, and key error path coverage. Replace all real Jira keys with fictional ones.

**Architecture:** Single file rewrite of `test/test_e2e.ml`. The existing `start`, `with_temp_config`, `test_config_with_mappings` helpers are reused. Watson report fixtures are updated to use fictional tickets. Tests use the continuation-based `Io.Mocked` system with `input`, `http_get`, `http_post`, `finish`.

**Tech Stack:** OCaml, ppx_expect, Io.Mocked effect handlers, Config sexp persistence

---

### Task 1: Update fixtures and helpers — remove real Jira keys

**Files:**
- Modify: `test/test_e2e.ml:7-20` (sample_watson_report)

**Step 1: Replace sample_watson_report**

Replace the `sample_watson_report` fixture. Change `FK-3080` → `DEV-101`, `FK-3083` → `DEV-202`, keep `architecture` and `breaks` and `cr` projects:

```ocaml
let sample_watson_report =
  {|Tue 03 February 2026 -> Tue 03 February 2026

architecture - 25m 46s

breaks - 1h 20m 39s
	[coffee     20m 55s]
	[lunch     59m 44s]

cr - 51m 02s
	[DEV-101     33m 35s]
	[DEV-202     12m 37s]

Total: 2h 37m 27s|}
```

**Step 2: Run tests to see what breaks**

Run: `opam exec -- dune runtest 2>&1 | head -60`
Expected: Several tests fail because expected output still references FK-* tickets.

**Step 3: Promote the changed expectations**

Run: `opam exec -- dune promote && opam exec -- dune runtest`
Expected: Tests pass (the old tests still work, just with updated ticket names in output).

**Step 4: Commit**

```
git add test/test_e2e.ml
git commit -m "test: replace real Jira keys with fictional tickets in e2e fixtures"
```

---

### Task 2: Write test "first-run: credentials, setup, and posting"

**Files:**
- Modify: `test/test_e2e.ml` — add new test after `open Io.Mocked`

This test starts with `Config.empty` (no saved config file), so the `run` function will prompt for all credentials, fetch account ID, discover work attributes, fetch categories, then process one entry and post it.

**Step 1: Write the test with empty expect blocks**

Add this test after `open Io.Mocked`:

```ocaml
let%expect_test "first-run: credentials, setup, and posting" =
  with_temp_config @@ fun ~config_path ->
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Tempo token (Input_secret) *)
    [%expect {||}];
    input t "test-tempo-token";
    (* Jira subdomain *)
    [%expect {||}];
    input t "mycompany";
    (* Jira email *)
    [%expect {||}];
    input t "user@example.com";
    (* Jira API token (Input_secret) *)
    [%expect {||}];
    input t "test-jira-token";
    (* Fetches account ID via GET *)
    [%expect {||}];
    http_get t { Io.status = 200; body = {|{"accountId": "acc-id-999"}|} };
    (* Fetches work attribute keys via GET *)
    [%expect {||}];
    http_get t { Io.status = 200; body = {|{"results": [
      {"name": "Account", "key": "_Account_"},
      {"name": "Category", "key": "_Category_"}
    ]}|} };
    (* Fetches category options via GET *)
    [%expect {||}];
    http_get t { Io.status = 200; body = {|{
      "names": {"dev": "Development", "met": "Meeting"},
      "values": ["dev", "met"]
    }|} };
    (* Now watson report is processed, entry prompt *)
    [%expect {||}];
    input t "PROJ-123";
    [%expect {||}];
    input t "first run work";
    (* Category prompt *)
    [%expect {||}];
    input t "1";
    (* Summary + confirmation *)
    [%expect {||}];
    input t "";
    (* Posting — needs issue lookup since no cached issue_ids *)
    [%expect {||}];
    http_get t { Io.status = 200; body = {|{
      "id": "67890",
      "names": {"customfield_10201": "Account"},
      "fields": {"customfield_10201": {"id": 273, "value": "Operations"}}
    }|} };
    [%expect {||}];
    http_get t { Io.status = 200; body = {|{"key": "ACCT-1", "name": "Operations"}|} };
    [%expect {||}];
    http_post t { Io.status = 200; body = {|{"id": 999}|} };
    [%expect {||}];
    finish t
```

**Step 2: Run tests, review output, promote**

Run: `opam exec -- dune runtest 2>&1 | head -120`

Review the diff carefully — it should show the full credential prompt sequence, then the entry processing. If output is correct:

Run: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m "test: add first-run credential and setup flow e2e test"
```

---

### Task 3: Write test "config round-trip: mappings persist across separate runs"

**Files:**
- Modify: `test/test_e2e.ml`

Two separate `start`/`finish` invocations sharing one `config_path`. Run 1 has no mappings; the user assigns a ticket and skips-always. Run 2 uses a different date and the mappings should auto-apply.

**Step 1: Write the test with empty expect blocks**

```ocaml
let%expect_test "config round-trip: mappings persist across separate runs" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson_day1 = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

breaks - 30m 00s

Total: 1h 30m 00s|} in
    let watson_day2 = {|Tue 04 February 2026 -> Tue 04 February 2026

coding - 2h 00m 00s

breaks - 45m 00s

Total: 2h 45m 00s|} in
    (* Run 1: assign coding -> PROJ-123, skip-always breaks *)
    let t1 = start ~watson_output:[("2026-02-03", watson_day1)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"])
    in
    [%expect {||}];
    input t1 "PROJ-123";
    [%expect {||}];
    input t1 "day one work";
    [%expect {||}];
    input t1 "1";
    [%expect {||}];
    input t1 "S";
    [%expect {||}];
    input t1 "n";
    [%expect {||}];
    finish t1;
    (* Run 2: same config_path, different date — mappings should auto-apply *)
    let t2 = start ~watson_output:[("2026-02-04", watson_day2)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-04"])
    in
    [%expect {||}];
    input t2 "";
    [%expect {||}];
    input t2 "";
    [%expect {||}];
    input t2 "n";
    [%expect {||}];
    finish t2
```

**Step 2: Run tests, review output, promote**

Run: `opam exec -- dune runtest 2>&1 | head -120`
Review: Run 1 should show full prompts. Run 2 should skip ticket/mapping prompts and go straight to description + category keep/change + summary.

Run: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m "test: add config round-trip persistence e2e test"
```

---

### Task 4: Write test "comprehensive interactive flow"

**Files:**
- Modify: `test/test_e2e.ml`

Replaces old tests "interactive flow prompts for unmapped entries" and "interactive flow with mixed decisions". Uses a watson report with 3 entries: `coding` (assign), `breaks` (skip once), `cr` with tags (split by tags).

**Step 1: Write the test with empty expect blocks**

```ocaml
let%expect_test "comprehensive interactive flow" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* architecture: assign ticket *)
    [%expect {||}];
    input t "ARCH-1";
    [%expect {||}];
    input t "arch work";
    [%expect {||}];
    input t "1";
    (* breaks: skip once *)
    [%expect {||}];
    input t "n";
    (* cr: split by tags *)
    [%expect {||}];
    input t "s";
    (* DEV-101 tag: accept (Enter = auto-accept ticket-pattern tag) *)
    [%expect {||}];
    input t "";
    [%expect {||}];
    input t "review work";
    (* DEV-202 tag: accept *)
    [%expect {||}];
    input t "";
    [%expect {||}];
    input t "";
    (* Category for DEV-101 *)
    [%expect {||}];
    input t "1";
    (* Category for DEV-202 *)
    [%expect {||}];
    input t "2";
    (* Summary + confirmation *)
    [%expect {||}];
    input t "n";
    [%expect {||}];
    finish t
```

Note: uses `sample_watson_report` (default) which now has DEV-101/DEV-202 tags from Task 1.

**Step 2: Run tests, review, promote**

Run: `opam exec -- dune runtest 2>&1 | head -120`
Run: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m "test: add comprehensive interactive flow e2e test"
```

---

### Task 5: Write test "cached mappings with auto_extract and ticket"

**Files:**
- Modify: `test/test_e2e.ml`

Replaces old "uses cached mappings with auto_extract" and "skips prompts for cached mappings". Config pre-loaded with Ticket, Skip, and Auto_extract mappings.

**Step 1: Write the test**

```ocaml
let%expect_test "cached mappings with auto_extract and ticket" =
  with_temp_config @@ fun ~config_path ->
    let config = {
      (test_config_with_mappings [
        ("architecture", Config.Ticket "ARCH-1");
        ("breaks", Config.Skip);
        ("cr", Config.Auto_extract);
      ]) with
      tempo_token = "existing-token-xyz";
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {||}];
    input t "";
    [%expect {||}];
    input t "1";
    [%expect {||}];
    input t "1";
    [%expect {||}];
    input t "1";
    [%expect {||}];
    input t "n";
    [%expect {||}];
    finish t
```

**Step 2: Run, review, promote**

Run: `opam exec -- dune runtest 2>&1 | head -80`
Run: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m "test: add cached mappings e2e test covering Ticket, Skip, Auto_extract"
```

---

### Task 6: Keep "handles empty watson report" test

**Files:**
- Modify: `test/test_e2e.ml` — keep as-is, no changes needed

This test is already minimal and tests distinct functionality. No action required.

---

### Task 7: Write test "posting: success, failure, and issue lookup"

**Files:**
- Modify: `test/test_e2e.ml`

Consolidates old "posts worklogs with mocked HTTP", "handles failed POST", and "looks up issue ID from Jira" into one test. Two entries: one with cached issue ID (succeeds), one needing Jira lookup (fails on POST).

**Step 1: Write the test**

```ocaml
let%expect_test "posting: success, failure, and issue lookup" =
  with_temp_config @@ fun ~config_path ->
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

review - 30m 00s

Total: 1h 30m 00s|} in
    let config = {
      (test_config_with_mappings [
        ("coding", Config.Ticket "PROJ-123");
        ("review", Config.Ticket "PROJ-456");
      ]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Description for PROJ-123 *)
    [%expect {||}];
    input t "test work";
    [%expect {||}];
    input t "1";
    (* Description for PROJ-456 *)
    [%expect {||}];
    input t "";
    [%expect {||}];
    input t "1";
    (* Summary + confirm *)
    [%expect {||}];
    input t "";
    (* Posting: PROJ-123 has cached issue_id, posts directly *)
    [%expect {||}];
    http_post t { Io.status = 200; body = {|{"id": 999}|} };
    (* PROJ-456 needs Jira lookup *)
    [%expect {||}];
    http_get t { Io.status = 200; body = {|{
      "id": "67890",
      "names": {"customfield_10201": "Account"},
      "fields": {"customfield_10201": {"id": 273, "value": "Ops"}}
    }|} };
    [%expect {||}];
    http_get t { Io.status = 200; body = {|{"key": "ACCT-2"}|} };
    (* PROJ-456 POST fails *)
    [%expect {||}];
    http_post t { Io.status = 400; body = {|{"error": "Invalid issue"}|} };
    [%expect {||}];
    finish t
```

**Step 2: Run, review, promote**

Run: `opam exec -- dune runtest 2>&1 | head -80`
Run: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m "test: add consolidated posting e2e test with success, failure, and lookup"
```

---

### Task 8: Write test "category selection and override"

**Files:**
- Modify: `test/test_e2e.ml`

Consolidates old "prompts for category" and "allows overriding cached category". Two entries: one with no cached category (prompted), one with cached category (keep/change).

**Step 1: Write the test**

```ocaml
let%expect_test "category selection and override" =
  with_temp_config @@ fun ~config_path ->
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

review - 30m 00s

Total: 1h 30m 00s|} in
    let config = {
      (test_config_with_mappings [
        ("coding", Config.Ticket "PROJ-123");
        ("review", Config.Ticket "PROJ-456");
      ]) with
      issue_ids = [("PROJ-123", 12345); ("PROJ-456", 67890)];
      account_keys = [("PROJ-123", "ACCT-1"); ("PROJ-456", "ACCT-2")];
      category_selections = [("PROJ-456", "dev")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* PROJ-123: description *)
    [%expect {||}];
    input t "";
    (* PROJ-123: no cached category → fresh prompt *)
    [%expect {||}];
    input t "2";
    (* PROJ-456: description *)
    [%expect {||}];
    input t "";
    (* PROJ-456: cached category → keep/change, user changes *)
    [%expect {||}];
    input t "c";
    [%expect {||}];
    input t "3";
    (* Summary + skip *)
    [%expect {||}];
    input t "n";
    [%expect {||}];
    finish t
```

**Step 2: Run, review, promote**

Run: `opam exec -- dune runtest 2>&1 | head -80`
Run: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m "test: add category selection and override e2e test"
```

---

### Task 9: Write test "multi-day with posting and skipping"

**Files:**
- Modify: `test/test_e2e.ml`

Consolidates old "multi-day processing" and "skip day continues to next day". Day 1: user skips. Day 2: cached mappings apply, user posts.

**Step 1: Write the test**

```ocaml
let%expect_test "multi-day with posting and skipping" =
  with_temp_config @@ fun ~config_path ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson_output = [
      ("2026-02-03", {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|});
      ("2026-02-04", {|Tue 04 February 2026 -> Tue 04 February 2026

coding - 2h 00m 00s

Total: 2h 00m 00s|});
    ] in
    let t = start ~watson_output ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"; "2026-02-04"])
    in
    (* Day 1: description *)
    [%expect {||}];
    input t "";
    (* Day 1: category *)
    [%expect {||}];
    input t "1";
    (* Day 1: skip day *)
    [%expect {||}];
    input t "n";
    (* Day 2: description *)
    [%expect {||}];
    input t "";
    (* Day 2: category (cached from day 1) *)
    [%expect {||}];
    input t "";
    (* Day 2: post *)
    [%expect {||}];
    input t "";
    [%expect {||}];
    http_post t { Io.status = 200; body = {|{"id": 999}|} };
    [%expect {||}];
    finish t
```

**Step 2: Run, review, promote**

Run: `opam exec -- dune runtest 2>&1 | head -80`
Run: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m "test: add multi-day posting and skipping e2e test"
```

---

### Task 10: Write test "split by tags: full and partial"

**Files:**
- Modify: `test/test_e2e.ml`

Consolidates old "split by tags creates per-tag decisions" and "split with tag skip". One entry with 3 tags: one accepted with default ticket, one given custom ticket, one skipped.

**Step 1: Write the test**

```ocaml
let%expect_test "split by tags: full and partial" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 1h 20m 02s
	[DEV-101     33m 35s]
	[review     12m 37s]
	[DEV-202     33m 50s]

Total: 1h 20m 02s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Entry prompt: split *)
    [%expect {||}];
    input t "s";
    (* DEV-101: accept default (ticket pattern, Enter) *)
    [%expect {||}];
    input t "";
    [%expect {||}];
    input t "review of DEV-101";
    (* review: assign custom ticket *)
    [%expect {||}];
    input t "REVIEW-55";
    [%expect {||}];
    input t "code review";
    (* DEV-202: skip *)
    [%expect {||}];
    input t "n";
    (* Categories for DEV-101 and REVIEW-55 *)
    [%expect {||}];
    input t "1";
    [%expect {||}];
    input t "2";
    (* Summary + skip *)
    [%expect {||}];
    input t "n";
    [%expect {||}];
    finish t
```

**Step 2: Run, review, promote**

Run: `opam exec -- dune runtest 2>&1 | head -100`
Run: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m "test: add split by tags e2e test with accept, custom, and skip"
```

---

### Task 11: Write test "failed credential API call aborts"

**Files:**
- Modify: `test/test_e2e.ml`

New error path test: empty config, user enters all credentials, but the Jira account ID fetch returns 401.

**Step 1: Write the test**

Note: `fetch_jira_account_id` failure causes a `failwith`, so the `Io.Mocked.run` session will end with an exception. We need to catch it. The test should use `Expect_test_helpers_core.require_does_raise` or just wrap in a try/with.

```ocaml
let%expect_test "failed credential API call aborts" =
  with_temp_config @@ fun ~config_path ->
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let raised = ref false in
    (try
      let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
        Main_logic.run ~config_path ~dates:[test_date])
      in
      input t "test-tempo-token";
      [%expect {||}];
      input t "mycompany";
      [%expect {||}];
      input t "user@example.com";
      [%expect {||}];
      input t "test-jira-token";
      [%expect {||}];
      http_get t { Io.status = 401; body = {|{"message": "Unauthorized"}|} };
      [%expect {||}];
      finish t
    with Failure msg ->
      raised := true;
      print_endline msg);
    [%expect {||}];
    assert !raised
```

**Step 2: Run, review, promote**

Run: `opam exec -- dune runtest 2>&1 | head -60`

Note: The exception from `failwith` may propagate differently through the effect handler. If it doesn't work cleanly with `try/with`, we may need to adjust — the exception should propagate through `Io.Mocked.run`. Review the actual behavior and adjust.

Run: `opam exec -- dune promote && opam exec -- dune runtest`

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m "test: add failed credential API call error path e2e test"
```

---

### Task 12: Delete old redundant tests

**Files:**
- Modify: `test/test_e2e.ml`

Delete the following old tests that are now covered by consolidated tests:

1. `"interactive flow prompts for unmapped entries"` — covered by "comprehensive interactive flow"
2. `"uses cached mappings with auto_extract"` — covered by "cached mappings with auto_extract and ticket"
3. `"interactive flow with mixed decisions"` — covered by "comprehensive interactive flow"
4. `"skips prompts for cached mappings"` — covered by "cached mappings with auto_extract and ticket"
5. `"posts worklogs with mocked HTTP"` — covered by "posting: success, failure, and issue lookup"
6. `"handles failed POST with error message"` — covered by "posting: success, failure, and issue lookup"
7. `"looks up issue ID from Jira when not cached"` — covered by "posting: success, failure, and issue lookup"
8. `"prompts for category per worklog when not cached"` — covered by "category selection and override"
9. `"allows overriding cached category per worklog"` — covered by "category selection and override"
10. `"multi-day processing with day headers"` — covered by "multi-day with posting and skipping"
11. `"skip day continues to next day"` — covered by "multi-day with posting and skipping"
12. `"split by tags creates per-tag decisions"` — covered by "split by tags: full and partial"
13. `"split with tag skip"` — covered by "split by tags: full and partial"

Keep only: `"handles empty watson report"`.

**Step 1: Delete all listed tests**

Remove the 13 old test blocks.

**Step 2: Run tests to verify nothing is broken**

Run: `opam exec -- dune runtest`
Expected: All new tests pass, old tests gone.

**Step 3: Commit**

```
git add test/test_e2e.ml
git commit -m "test: remove 13 redundant e2e tests replaced by consolidated suite"
```

---

### Task 13: Final verification

**Step 1: Run full test suite**

Run: `opam exec -- dune runtest`
Expected: All tests pass.

**Step 2: Review the final test file**

Read through `test/test_e2e.ml` and verify:
- No FK-* or other real Jira keys remain
- All 10 tests are present and passing
- No dead code or unused helpers

**Step 3: Final commit if any cleanup needed**

```
git add test/test_e2e.ml
git commit -m "test: final cleanup of e2e test suite"
```
