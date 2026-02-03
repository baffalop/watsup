# Watsup: Watson to Jira Tempo CLI

## Overview

An OCaml CLI that reads Watson time tracking reports and posts worklogs to Jira Tempo. Interactive prompts let you map Watson projects to Jira tickets, with cached defaults for efficiency.

## Tech Stack

- OCaml 5.4
- Core (stdlib)
- Angstrom (parser combinators)
- Cohttp-lwt-unix (HTTP client)
- ppx_jane, ppx_expect, ppx_inline_test (testing)
- Sexp for config/cache persistence

## Core Data Model

### Watson Entry (parsed from report)

```ocaml
type tag = {
  name : string;
  duration : Duration.t;
}

type entry = {
  project : string;
  total : Duration.t;
  tags : tag list;
}
```

### Mapping (cached)

```ocaml
type mapping =
  | Ticket of string    (* default suggestion, still prompts *)
  | Skip                (* skip always, no prompt *)
  | Auto_extract        (* cr-style: extract ticket patterns from tags *)
```

### Worklog (ready to post)

```ocaml
type worklog = {
  ticket : string;
  duration : Duration.t;  (* rounded to 5 min *)
  date : Date.t;
  category : string;
  account : string;
  message : string option;
}
```

### Config (persisted)

```ocaml
type category_cache = {
  selected : string;
  options : string list;
  fetched_at : Time.t;
}

type config = {
  tempo_token : string;
  category : category_cache option;
  mappings : (string * mapping) list;
}
```

**Location:** `~/.config/watsup/config.sexp`

**Format:**
```sexp
((tempo_token "your-token-here")
 (category
  ((selected Development)
   (options (Development Meeting Support Review))
   (fetched_at 2026-02-03T10:00:00Z)))
 (mappings
  ((packaday (Ticket PACK-123))
   (proj (Ticket LOG-16))
   (breaks Skip)
   (cr Auto_extract))))
```

## Auto-Extraction Rules

- Ticket pattern: `[A-Z]+-\d+`
- `cr` project (and any `Auto_extract` mapping): tags matching ticket pattern become individual worklogs; non-matching tags (names) are ignored

## CLI Interaction Flow

### Startup

1. First run: prompt for Tempo API token, fetch and cache Category list
2. Parse `watson report -dG` output
3. Load cached mappings

### Per-Entry Prompts

For entries without cached skip:

```
packaday - 2h 30m (rounded)
  Cached: PACK-123
  [Enter] accept | [ticket] override | [s]plit | [n]skip | [S]kip always
  [m]essage | [c]ategory (current: Development)
> _
```

For auto-extracted tickets (cr-style):

```
cr: FK-3080 - 35m
  Auto-extracted from tag
  [Enter] confirm | [n]skip
> _
```

### Split Mode (after pressing `s`)

```
packaday [setup] - 1h 30m
  [ticket] assign | [n]skip | [q]uit split
> _
```

### Key Bindings

| Key | Action |
|-----|--------|
| Enter | Accept suggested mapping |
| (type ticket) | Override with new ticket number |
| s | Split into tags |
| n | Skip this entry (one-time) |
| S | Skip always (cache the skip) |
| m | Add message |
| c | Change category |
| r | Refresh category list from API |

## Summary & Posting

After all entries processed:

```
=== Worklogs to Post ===
FK-3080     cr              35m   Development
FK-3083     cr              15m   Development
PACK-123    packaday      2h 30m  Development
LOG-16      proj            55m   Development
                          ------
Total:                    4h 15m  (target: 7h 30m)

=== Skipped (cached) ===
breaks                    1h 20m

=== Manual Required (no Account) ===
ARCH-99     architecture    25m   [no account found]

[Enter] post all | [q]uit without posting
> _
```

### Posting Behavior

- Post each worklog to Tempo API sequentially
- Show progress: `Posting FK-3080... done`
- On error: show which failed, continue with rest
- Final summary: X posted, Y failed, Z require manual entry

## Tempo API Integration

### Endpoints

1. **GET categories** - `/work-attributes` or similar
   - Fetch once, cache locally
   - Refresh with `r` keybinding

2. **GET account for ticket** - check if ticket has default account
   - Called when ticket is selected
   - If empty, flag for manual entry

3. **POST worklog** - `/worklogs`
   - Ticket (issue key)
   - Time spent (seconds)
   - Start date
   - Category (attribute)
   - Account
   - Description (optional)

### Auth

Bearer token in header, stored in config file.

### Error Handling

- 401: prompt to re-enter token
- 400/422: show API error message, flag entry as failed
- Network errors: retry once, then flag as failed

## Project Structure

```
watsup/
├── bin/
│   └── main.ml              # CLI entry point
├── lib/
│   ├── watson.ml(i)         # Parse watson report output
│   ├── tempo.ml(i)          # Tempo API client
│   ├── config.ml(i)         # Load/save config + mappings cache
│   ├── prompt.ml(i)         # Interactive prompts, keybindings
│   ├── worklog.ml(i)        # Core types
│   ├── duration.ml(i)       # Duration type + rounding
│   └── ticket.ml(i)         # Ticket pattern matching
├── test/
│   └── (inline in each .ml)
├── dune-project
├── dune
└── watsup.opam
```

### Dependencies

- core
- angstrom
- cohttp-lwt-unix
- yojson
- ppx_jane
- ppx_expect
- ppx_inline_test
- ppx_sexp_conv

### Setup

- `dune init` for scaffolding
- Create opam switch for isolation
- Dependencies declared in dune-project
- `.mli` for every module

## Testing Strategy

### Expect Tests (inline)

Test functions exposed through `.mli` interfaces:

```ocaml
let%expect_test "parse_entry" =
  let input = "packaday - 2h 28m 32s\n\t[setup  1h 29m 04s]\n" in
  let result = parse_entry input in
  print_s [%sexp (result : entry Or_error.t)];
  [%expect {| ... |}]
```

### What to Test

- Watson parsing (various formats, edge cases)
- Duration parsing and rounding
- Ticket pattern matching
- Config sexp round-tripping
- Mapping logic (auto-extract, cached suggestions)
- Config caching (with temp file for path)

### Integration Testing

Parameterize config path to use temp files:

```ocaml
let%expect_test "config_round_trip" =
  let path = Filename_unix.temp_file "watsup" ".sexp" in
  (* ... test save/load cycle ... *)
  Unix.unlink path
```

### Not Unit Tested (manual/integration)

- Tempo API calls (mock or live testing)
- Interactive prompts (manual testing)

## Duration Rounding

All durations rounded to nearest 5 minutes before posting.

```ocaml
(* 28m -> 30m, 32m -> 30m, 33m -> 35m *)
let round_5min duration = ...
```

## Future Considerations (out of scope)

- Keychain integration for token storage
- Multiple Tempo instances
- Date range support (not just today)
- Undo/edit posted worklogs
