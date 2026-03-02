# UX Improvements Design

## Problem

The CLI becomes hard to use once mappings are cached. The prompt doesn't provide enough context for decisions — cached entries skip straight to description prompts without showing what project/tag/duration is being processed. The Auto_extract feature silently skips prompts entirely. Two redundant summaries at the end add noise.

## Changes

### 1. Watson report tee to terminal

Modify the Watson command to `CLICOLOR_FORCE=1 watson report ... | tee /dev/stderr`. Stderr shows colored output on the terminal; stdout is captured for parsing. Replaces the `Report: ...` summary line. No test coverage needed for the display aspect (mocked as no-op in tests).

### 2. Entry context always shown + combined cached prompt

Every entry displays its context (project, tags, duration) regardless of cached state.

For cached/auto-detected entries, a combined prompt offers control:

```
coding - 1h  [-> PROJ-123]
  [Enter] keep | [t] ticket | [c] category | [n] skip:
```

Description is always prompted separately (never cached — it describes the specific day's work).

For uncached entries (no cache, no ticket pattern detected), the existing prompt format continues:

```
coding - 1h
  [ticket] assign | [n] skip | [S] skip always:
```

For split tags, same pattern applies per-tag with composite context.

### 3. Remove Auto_extract mapping type, add auto-detection behavior

Remove `Auto_extract` from `Config.mapping` variant type. Replace with runtime behavior:

- When any project name or tag name matches the Jira ticket pattern (`[A-Z]+-[0-9]+`), automatically treat it as `Ticket("DEV-123")`
- Cache it immediately as a normal `Ticket` mapping
- Show it in the cached-entry flow (with option to override)

This happens in the orchestration layer (`main_logic.ml`), before calling `process_entry`. The Processor stays pure — it just receives `cached = Some (Ticket ...)` or `None`.

### 4. Composite keys for split tag mappings

When tags are mapped during a split, cache with `"project:tag"` composite key (e.g., `"cr:review"` -> `Ticket "REVIEW-55"`).

Lookup order:
- For a split tag: check `"project:tag"` key
- For a standalone project: check `"project"` key only

This prevents a mapping for `cr:review` from applying to a standalone `review` project.

### 5. Combined summary

Merge the two current summary sections (`=== Summary ===` and `=== Worklogs to Post ===`) into one, grouped by action:

```
=== Summary ===
Post:
  ARCH-1     (25m)  [Development]  architecture   "arch work"
  DEV-101    (35m)  [Development]  cr:DEV-101     "review"
  DEV-202    (10m)  [Meeting]      cr:DEV-202
Skip:
  breaks     (1h 20m)

[Enter] post | [n] skip day:
```

### 6. Description always fresh

Descriptions are already prompted per-run for `Ticket` mappings. Removing `Auto_extract` (which hardcoded empty descriptions) fixes the remaining gap. No description caching.
