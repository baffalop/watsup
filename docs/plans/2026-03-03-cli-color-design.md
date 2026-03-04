# CLI Color Output Design

## Problem

All CLI output is plain text. Adding color improves scanability during interactive use and when reviewing summaries/posting results.

## Approach

Tagged string format parsed at runtime, with a new `Set_color` algebraic effect that is no-oped in tests.

## New Effect: `Set_color`

```ocaml
type color = Reset | Bold | Dim | Red | Green | Yellow | Blue | Cyan
type _ Effect.t += Set_color : color -> unit Effect.t
```

- `Io.with_stdio`: emits ANSI escape codes to stdout
- `Io.Mocked.run`: no-op (expect blocks stay clean)

## Styled Output: `Io.styled`

```ocaml
Io.styled "{header}=== Summary ==={/}\n"
Io.styled @@ sprintf "{ok}%s: OK{/}\n" ticket
Io.styled @@ sprintf "{err}%s: FAILED (%d){/}\n" ticket status
```

`Io.styled` parses the string, splitting on `{tagname}` and `{/}` (reset). For each segment it emits `Set_color` then `Output` effects. Unknown tags pass through as literal text.

## Semantic Color Map

| Tag | ANSI | Used for |
|-----|------|----------|
| `{header}` | Bold | Section headers, day headers |
| `{ok}` | Green | OK status, successful posts |
| `{err}` | Red | FAILED status, errors |
| `{warn}` | Yellow | Warnings |
| `{info}` | Cyan | Auto-split marker, informational |
| `{dim}` | Dim | "Looking up..." status, skip entries in summary, response bodies |
| `{action}` | Blue | Current decision/ticket being evaluated (`[skip]`, `[-> DEV-42 "..."]`) |
| `{prompt}` | Dim | Interactive prompt options (`[Enter] keep | [t] ticket...`) |

## Migration

Change `Io.output` calls to `Io.styled` where color is wanted. Plain `Io.output` remains for uncolored output.

## Testing

- Inline `%expect_test` in styled parser for tag parsing
- E2E tests unchanged — `Set_color` no-oped, expect blocks stay clean
