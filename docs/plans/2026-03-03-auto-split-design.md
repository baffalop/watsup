# Auto-Split for Multi-Tag Worklogs

## Problem

When a worklog has a project + multiple tags, and some tags already have cached composite key mappings (e.g., `cr:DEV-101 -> Ticket "DEV-101"`), the user must manually choose `[s] split` every time. This loses the convenience of those cached mappings.

## Desired Behavior

| Scenario | Behavior |
|----------|----------|
| Project has mapped ticket, entry has tags | Show cached prompt with `[s] split` option |
| 1 tag has composite mapping | Show that tag's ticket as speculative cached mapping, offer `[s] split` |
| 2+ tags have composite mappings | Auto-split: announce, go straight to per-tag handling |
| No mappings | Existing uncached flow (unchanged) |

## Design

### `Processor.resolve_entry_mapping` (pure function)

New type and function in `processor.ml`:

```ocaml
type entry_resolution =
  | Project_cached of string
  | Project_skip
  | Tag_inferred of string
  | Auto_split
  | Uncached

val resolve_entry_mapping
  :  config:Config.t
  -> project:string
  -> tags:Watson.tag list
  -> entry_resolution
```

Logic:
1. Check project-level mapping (config lookup + `is_ticket_pattern` fallback)
2. If found → `Project_cached ticket` or `Project_skip`
3. Otherwise scan tags for composite key mappings (`project:tag` in config, or tag matches `is_ticket_pattern`)
4. Count: 0 → `Uncached`, 1 → `Tag_inferred ticket`, 2+ → `Auto_split`

### `main_logic.ml` orchestration changes

Replace inline cache lookup in `run_day` with call to `resolve_entry_mapping`, then dispatch:

- **`Project_cached`**: existing `prompt_cached_entry` flow, extended with `[s] split` when entry has tags
- **`Project_skip`**: existing `prompt_cached_skip` flow
- **`Tag_inferred`**: same UX as `Project_cached` (show ticket, keep/ticket/split/skip). "Keep" posts whole entry. No project-level mapping saved.
- **`Auto_split`**: announce "auto-splitting", call `handle_split_tags` directly
- **`Uncached`**: existing `run_uncached` flow

### `prompt_cached_entry` changes

- New `~has_tags:bool` parameter
- When `has_tags = true`: show `[Enter] keep | [t] ticket | [s] split | [c] category | [n] skip`
- `cached_response` type gains a `Split` variant

### Clearing project mapping on split

When `handle_split_tags` runs (from any entry point), remove the project-level mapping after saving composite keys. This ensures next run routes through `Tag_inferred` or `Auto_split` instead.

### Testing

**Unit tests (processor.ml)** — heavy lifting:
- All 5 resolution variants with expect tests
- Edge cases: ticket-pattern tags, mixed mapped/unmapped, project mapping precedence

**E2E tests (test_e2e.ml)** — wiring verification:
- Auto-split happy path (2 mapped tags)
- Split from cached entry (user picks `[s]`, project mapping cleared)
