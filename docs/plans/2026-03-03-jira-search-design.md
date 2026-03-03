# Jira Ticket Search & Completion

## Overview

Add inline Jira ticket search to the ticket assignment prompts. Instead of requiring users to remember and type exact ticket keys, the prompt suggests search terms derived from the Watson entry context (project name + tags) and lets users search Jira interactively.

## Goals

1. Reduce friction in ticket assignment by surfacing relevant Jira tickets
2. Validate ticket assignments against Jira (no more blind assignments)
3. Show ticket summaries for cached mappings (fetched on prompt, not persisted)
4. Keep the implementation testable within the existing IO effect system
5. Prevent JQL injection via thorough input sanitization

## Non-Goals

- Terminal raw mode / search-as-you-type (standard cooked stdin/stdout only)
- Caching ticket summaries in config
- Pulling starred/favourite projects from Jira (local config only)
- "Broaden search" fallback (future enhancement)

## New Module: `Jira_search`

Standalone module (`lib/jira_search.ml/.mli`) owning all search and lookup logic, with its own tests.

### Types

```ocaml
type search_result = { key : string; summary : string; id : int }

type prompt_outcome =
  | Selected of search_result
  | Skip_once
  | Skip_always
  | Split
```

### Key Functions

- **`sanitize_jql_text`** — escape user input for safe inclusion in JQL `text ~ "..."`. Pure, heavily unit-tested.
- **`validate_project_key`** — validate project key format (`^[A-Z][A-Z0-9_]+$`). Pure, unit-tested.
- **`build_search_jql`** — build scoped JQL from search terms, starred projects, log date. Pure, unit-tested.
- **`search`** — `http_get` to `/rest/api/2/search`, parse response into `search_result list`.
- **`lookup`** — `http_get` to `/rest/api/2/issue/{key}?fields=summary`, return single result or error.
- **`prompt_loop`** — interactive search-select loop using IO effects.

## Search Scoping (JQL)

Text search uses scoped JQL:

```sql
text ~ "sanitized terms"
AND (status != Done OR (status = Done AND updated >= "2026-02-17"))
AND (
  assignee = currentUser()
  OR reporter = currentUser()
  OR project in (DEV, ARCH)
)
ORDER BY updated DESC
```

- **Recently closed window:** log date minus 14 days
- **User-touched:** `assignee = currentUser() OR reporter = currentUser()` (JQL function, no account ID needed)
- **Starred projects:** from config `starred_projects` field, validated as project keys
- **Max results:** 5
- **Fields:** `summary,status` (minimal response)

Direct ticket lookup is always unscoped: `GET /rest/api/2/issue/{key}?fields=summary`.

## JQL Injection Prevention

`sanitize_jql_text` handles:
- Escape double quotes (`"` -> `\"`)
- Escape backslashes (`\` -> `\\`)
- Strip/escape JQL-special characters: `{`, `}`, `(`, `)`, `[`, `]`
- Truncate excessively long input
- Reject empty/whitespace-only input

`validate_project_key` ensures starred project keys match `^[A-Z][A-Z0-9_]+$` before inclusion in JQL.

Unit tests cover: special characters, reserved words, empty input, long input, unicode, nested quotes.

## Prompt UX

### Uncached Entry (no tags)

```
coding - 1h
  [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always:
> <Enter>
  1. CODE-42  Refactor authentication module
  2. CODE-18  Fix coding standards linter
  3. CODE-7   Update coding guidelines
  4. CODE-3   Coding environment setup
  5. CODE-1   Initial coding standards doc
  [#] select | [text] search again | [n] back:
> 1
Description for CODE-42 (optional):
```

### Uncached Entry (with tags)

```
cr - 50m
  [DEV-101  35m]
  [review   10m]

  [Enter] search "cr" | [ticket/search] | [s] split | [n] skip | [S] skip always:
```

### Direct Ticket Input (auto-detected by pattern)

```
> DEV-123
  DEV-123  Refactor authentication module
  [Enter] confirm | [text] search again | [n] back:
```

On lookup failure:

```
> DEV-123
  DEV-123: not found (404)
  [text] try again | [n] back:
```

### Search Results Loop

After search results are displayed, the user can:
- Type a number (`1`-`5`) to select a result
- Type text to search again
- Type a ticket key (auto-detected) to look it up directly
- Type `n` to go back to the entry prompt

### Cached Entry (with inline title fetch)

```
  Looking up PROJ-123...
coding - 1h  [-> PROJ-123 "Fix OAuth token refresh"]
  [Enter] keep | [t] ticket | [c] category | [n] skip:
```

On fetch failure (mapping cleared, falls through to uncached):

```
  Looking up PROJ-123... not found (404)
coding - 1h
  [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always:
```

### Split Tag Prompts

Same search capability applies to individual tag prompts. Tags matching ticket patterns still auto-map; non-ticket tags get search hints using `project:tag` as terms.

## Config Changes

Single new field:

```sexp
(starred_projects (DEV ARCH))
```

No summary caching. `[@default []]` for backwards compatibility.

### CLI Command

```bash
watsup --star-projects DEV,ARCH
```

Overwrites `starred_projects` in config. Validates each key against `^[A-Z][A-Z0-9_]+$`.

### Startup Prompt

On startup, if `starred_projects` is empty, prompt the user to configure them:

```
No starred projects configured.
Enter comma-separated Jira project keys to prioritise in search (e.g. DEV,ARCH):
> DEV,LOG
Starred projects: DEV, LOG
```

Saved to config immediately. Runs once — after initial setup the prompt doesn't appear again.

## Integration with `main_logic.ml`

- `prompt_uncached_entry` calls `Jira_search.prompt_loop` instead of the current simple input
- `prompt_cached_entry` calls `Jira_search.lookup` before displaying the cached prompt
- On cached lookup failure: warn, clear mapping from config, fall through to uncached flow
- Log date and starred projects passed through to search functions

## Testing Strategy

### Unit Tests (inline in `jira_search.ml`)

- JQL sanitization: special chars, reserved words, empty input, long input, unicode, nested quotes
- JQL building: with/without starred projects, with/without log date, edge cases
- Project key validation: valid keys, invalid keys, empty
- Result parsing: valid JSON, malformed JSON, missing fields, empty results

### Mocked IO Tests (in `jira_search.ml` or separate test file)

- Search flow: user enters search terms, sees results, selects one
- Lookup flow: user types ticket key, sees confirmation, accepts
- Error handling: API failures, empty results, invalid ticket
- Prompt loop: multiple rounds of searching, back navigation
- Cached entry refresh: success and failure paths

### Temporary `--search` CLI Flag

Standalone mode that runs `Jira_search.prompt_loop` in isolation for manual testing against real Jira. Accepts a log date argument. Uses real config for credentials and starred projects. To be removed after integration is complete.

### Manual Testing Checkpoints

Implementation should pause for manual `--search` testing at:
1. After JQL building works (verify queries against real Jira)
2. After search results display correctly
3. After full prompt loop works end-to-end
