# Watsup: Watson to Tempo Time Tracking

## Purpose

Watsup bridges the gap between local time tracking with [Watson](https://github.com/TailorDev/Watson) and cloud-based time logging in [Tempo Timesheets](https://www.tempo.io/) for Jira. It allows developers to track time locally using Watson's simple CLI, then batch-sync their worklogs to Tempo at the end of each day or week.

## Goals

1. **Minimal friction** - Quick sync workflow that respects existing Watson habits
2. **Smart caching** - Remember ticket mappings so repeat entries don't need re-assignment
3. **Testability** - Full test coverage with dependency injection for all external IO
4. **Safety** - Confirmation before posting, clear error messages, no silent failures

## Design Philosophy

### Separation of IO from Logic

All external interactions (stdin, stdout, filesystem, HTTP, shell commands) are abstracted through the `Io.t` record. This enables:
- Unit testing with mocked IO
- E2E testing without real network calls
- Clear boundaries between pure logic and side effects

### Pure Business Logic

The `Processor` module contains pure functions for entry processing decisions. Given an entry and cached mappings, it returns decisions without any IO.

### Incremental Feature Building

Each feature is built as a testable increment:
1. Token management (prompt, cache, reuse)
2. Watson report parsing
3. Entry processing logic
4. Interactive prompts
5. API integration

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         bin/main.ml                             │
│                    (thin entry point)                           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      lib/main_logic.ml                          │
│              (orchestration, credential prompts,                │
│               Jira/Tempo API calls, posting flow)               │
└─────────────────────────────────────────────────────────────────┘
         │              │              │              │
         ▼              ▼              ▼              ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│   Io.t      │ │  Config     │ │  Processor  │ │   Watson    │
│ (IO abstrac)│ │ (persist)   │ │ (pure logic)│ │  (parsing)  │
└─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘
```

### Key Modules

| Module | Responsibility |
|--------|----------------|
| `Io` | Dependency injection for all external IO (stdin, stdout, HTTP, shell) |
| `Config` | Configuration persistence (tokens, mappings, cached issue IDs) |
| `Watson` | Parse Watson CLI output into structured entries |
| `Duration` | Time duration parsing and formatting |
| `Processor` | Pure entry processing logic (ticket assignment, skip decisions) |
| `Ticket` | Extract ticket IDs from tags |
| `Main_logic` | Orchestrate the full workflow |

### Data Flow

```
Watson CLI → Parse → Process Entries → Prompt User → Resolve IDs → POST to Tempo
    │                     │                              │
    │                     ▼                              ▼
    │              Use cached mappings           Use cached issue IDs
    │              or prompt for new             or fetch from Jira
    │                     │                              │
    │                     ▼                              ▼
    └──────────────► Save to Config ◄────────────────────┘
```

## Configuration

Config is stored at `~/.config/watsup/config.sexp`:

```sexp
((tempo_token "...")
 (jira_token "...")
 (jira_base_url "https://company.atlassian.net")
 (jira_account_id "...")
 (issue_ids ((PROJ-123 12345) (PROJ-456 67890)))
 (mappings
   ((breaks Skip)
    (coding (Ticket PROJ-123))
    (cr Auto_extract))))
```

### Mapping Types

- `Ticket "PROJ-123"` - Always post to this ticket
- `Skip` - Never post (e.g., breaks)
- `Auto_extract` - Extract ticket IDs from tags (e.g., `cr` with tags `FK-123`, `FK-456`)

## Outstanding Features

### Blocking: OAuth 2.0 Authorization Code Flow

Jira Cloud requires proper OAuth 2.0 flow for granular scopes:
- [ ] Register OAuth app at developer.atlassian.com
- [ ] CLI opens browser to authorization URL
- [ ] Localhost HTTP server receives callback with auth code
- [ ] Exchange code for access_token + refresh_token
- [ ] Automatic token refresh when expired

### Future Enhancements

- [ ] `--dry-run` flag to preview without posting
- [ ] Date range selection (not just today)
- [ ] Edit/delete previously posted worklogs
- [ ] Tempo work attributes (category, account)
- [ ] Multiple Jira instance support
- [ ] Config validation and migration tooling

## Dependencies

- **OCaml 5.4** with local opam switch
- **Core** - Standard library replacement
- **Angstrom** - Parser combinators for Watson output
- **Cohttp-lwt-unix** - HTTP client
- **ppx_jane** - Sexp derivation and inline tests
- **ppx_expect** - Expect tests
- **Yojson** - JSON parsing/generation
