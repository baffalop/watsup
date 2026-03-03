# E2E Test Redesign

## Problem

The 14 existing e2e tests have significant overlap and miss critical flows: first-run credential setup, config persistence round-trips, and key error paths. Real Jira keys (FK-*) leaked into test data.

## Design

Restructure from 14 tests to 10: consolidate redundant tests, add 3 new ones (first-run, round-trip, error path), replace all ticket references with fictional ones (DEV-101, PROJ-123, etc.).

### Test Suite

| # | Test Name | Type | Covers |
|---|-----------|------|--------|
| 1 | first-run: credentials, setup, and posting | NEW | All credential prompts, API discovery (account ID, work attrs, categories), then one entry posted |
| 2 | config round-trip: mappings persist across separate runs | NEW | Run 1: assign + skip-always. Run 2: separate invocation, same config_path, mappings auto-applied |
| 3 | comprehensive interactive flow | CONSOLIDATE | Assign ticket (no tags), split by tags, skip once, category selection — one richer watson report |
| 4 | cached mappings with auto_extract and ticket | CONSOLIDATE | Pre-set Ticket + Skip + Auto_extract mappings, all bypass prompts |
| 5 | empty watson report | KEEP | Zero entries handled gracefully |
| 6 | posting: success, failure, and issue lookup | CONSOLIDATE | Multiple worklogs: cached issue ID + Jira lookup, one OK + one FAILED |
| 7 | category selection and override | CONSOLIDATE | Fresh category prompt + cached category keep/change |
| 8 | multi-day with posting and skipping | CONSOLIDATE | Day 1 skip, day 2 post, day headers, cached mappings on day 2 |
| 9 | split by tags: full and partial | CONSOLIDATE | 3 tags: accept as-is, custom ticket, skip — covers both split paths |
| 10 | failed credential API call aborts | NEW | Empty config, creds entered, account ID fetch 401 → abort |

### Fictional Tickets

Replace all FK-* references with:
- `DEV-101`, `DEV-202` — generic dev tickets
- `PROJ-123` — project ticket (existing tests already use this)
- `REVIEW-55` — for split/tag scenarios
- `ACCT-456` — account keys

### Watson Report for Test 3

```
coding - 2h 00m 00s

breaks - 30m 00s

cr - 51m 02s
	[DEV-101     33m 35s]
	[DEV-202     12m 37s]

Total: 3h 21m 02s
```

### Round-Trip Test Structure (Test 2)

```
with_temp_config @@ fun ~config_path ->
  (* Run 1: empty config with pre-set credentials *)
  let t1 = start ~config_path ... in
  (* user assigns "coding" -> PROJ-123, skips "breaks" always *)
  finish t1;

  (* Run 2: same config_path, different date *)
  let t2 = start ~config_path ... in
  (* PROJ-123 auto-assigned, breaks auto-skipped *)
  finish t2;
```

### Decisions

- Both multi-day (in-memory) and separate-invocation (file persistence) round-trips
- Full mock for credential flow (all HTTP GETs)
- Key error paths only (failed account ID fetch)
- Consolidate where overlap exists
