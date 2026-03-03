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

### Incremental Feature Building

Each feature is built as a testable increment:
1. Token management (prompt, cache, reuse)
2. Watson report parsing
3. Entry processing logic
4. Interactive prompts with Jira search
5. API integration

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         bin/main.ml                             │
│            (CLI arg parsing with Climate, date resolution)      │
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
│   Io.t      │ │  Config     │ │ Jira_search │ │   Watson    │
│ (IO abstrac)│ │ (persist)   │ │ (search/    │ │  (parsing)  │
│             │ │             │ │  lookup)    │ │             │
└─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘
                                       │
                                       ▼
                                ┌─────────────┐
                                │   Ticket    │
                                │ (patterns)  │
                                └─────────────┘
```

### Key Modules

| Module | Responsibility |
|--------|----------------|
| `Io` | Dependency injection for all external IO (stdin, stdout, HTTP, shell) |
| `Config` | Configuration persistence (tokens, mappings, cached issue IDs, work attributes) |
| `Watson` | Parse Watson CLI output into structured entries |
| `Duration` | Time duration parsing and formatting |
| `Jira_search` | Interactive Jira ticket search, lookup, and prompt loop (JQL queries via Jira REST API v3) |
| `Ticket` | Ticket ID and project key pattern detection and extraction |
| `Main_logic` | Orchestrate the full workflow |

### Data Flow

```
CLI Args → Resolve Dates → [Per Day Loop]:
  Watson CLI → Parse → Process Entries → Jira Search → Resolve IDs → POST to Tempo
      │                     │                │               │              │
      │                     ▼                ▼               ▼              ▼
      │              Use cached mappings  Search Jira   Use cached issue  Include work
      │              or prompt for new    by text or    IDs + account     attributes
      │              (split by tags)      direct lookup keys or fetch     (Account +
      │                     │             per ticket    from Jira/Tempo   Category)
      │                     ▼                                  │
      └──────────────► Save to Config ◄────────────────────────┘
```

For each ticket prompt, the `Jira_search` module provides an interactive search loop:
1. Suggests search terms from the Watson entry's project and tags
2. Detects ticket patterns (e.g. `DEV-101`) and does direct Jira lookup
3. For text queries, searches via scoped JQL (starred projects, user-touched, recently closed)
4. Displays up to 5 results for selection
5. Validates chosen tickets against Jira before assignment

## Configuration

Config is stored at `~/.config/watsup/config.sexp`:

```sexp
((tempo_token "...")
 (jira_email "user@company.com")
 (jira_token "...")
 (jira_base_url "https://company.atlassian.net")
 (jira_account_id "...")
 (issue_ids ((PROJ-123 12345) (PROJ-456 67890)))
 (account_keys ((PROJ-123 ACCT-1)))
 (tempo_account_attr_key _Account_)
 (tempo_category_attr_key _Category_)
 (category
  ((selected dev-uuid-here)
   (options ((dev-uuid-here Development) (mtg-uuid Meeting)))
   (fetched_at 2026-02-07)))
 (starred_projects (DEV LOG))
 (mappings
   ((breaks Skip)
    (coding (Ticket PROJ-123))
    (cr:DEV-101 (Ticket DEV-101)))))
```

### Mapping Types

- `Ticket "PROJ-123"` - Post to this ticket (prompted to keep or change on each run)
- `Skip` - Skip this entry (prompted to keep or assign ticket on each run)

Split tag mappings use composite keys like `cr:DEV-101` to avoid cross-contamination between projects. Projects and tags matching Jira ticket patterns (e.g. `DEV-101`) are auto-mapped on first encounter.

## CLI Usage

```bash
watsup                              # today (default)
watsup -d 2026-02-05                # specific ISO date
watsup -d -2                        # 2 days ago (relative)
watsup -f 2026-02-03 -t 2026-02-07  # range, processed day-by-day
watsup --star-projects DEV,LOG      # add starred projects for search scoping
watsup --search metricinput         # test Jira search prompt in isolation
```

Date ranges are processed one day at a time, each with its own entry prompts, summary, and confirmation step. Skipping a day (`n` at confirmation) continues to the next day.

On first run (or if not yet configured), watsup prompts for starred Jira project keys. These scope search results to relevant projects. Use `--star-projects` to update them later.

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
- [ ] Edit/delete previously posted worklogs
- [x] Tempo work attributes (category, account)
- [x] Date range selection (`-d`, `-f`/`-t`)
- [x] Split entries by tags with per-tag ticket assignment
- [x] Per-ticket description prompts
- [x] Interactive Jira ticket search with scoped JQL
- [x] Starred projects for search scoping
- [ ] Multiple Jira instance support
- [ ] Config validation and migration tooling

## Dependencies

- **OCaml 5.4** with local opam switch
- **Core** - Standard library replacement
- **Angstrom** - Parser combinators for Watson output
- **Cohttp-lwt-unix** - HTTP client
- **Climate** - Declarative CLI argument parsing
- **ppx_jane** - Sexp derivation and inline tests
- **ppx_expect** - Expect tests
- **Yojson** - JSON parsing/generation
