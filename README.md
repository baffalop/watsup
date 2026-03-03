# Watsup

An interactive tool to post your [Watson](https://github.com/jazzband/watson) logs to [Jira Tempo](https://tempo.io/).

Built with OCaml (and Claude Code, with thanks to [obra](https://github.com/obra/superpowers)). Verified, QA'd and artisinally improved with human ❤️.

## Install, Build, Develop

(Requires OCaml, Dune)

```sh
# install dependencies
opam switch create . --deps-only

# just build
dune build

# or build and run
dune exec watsup

# or globally install executable
dune install --prefix=$HOME/.local/ # or --prefix=/usr/local/

# run tests
dune runtest
```

Tests are [expect-tests](https://github.com/janestreet/ppx_expect)—similar to snapshots. Output when they pass is just "Success"; on failure they output a diff with the changed expectation. If the new output is correct, apply the patch directly to the source file with `dune promote`.

## Usage

```sh
watsup                              # sync today's Watson logs (default)
watsup -d 2026-02-05                # specific date
watsup -d -1                        # yesterday
watsup -d -2                        # two days ago
watsup -f 2026-02-03 -t 2026-02-07  # date range (processed day by day)
watsup --star-projects DEV,LOG      # add starred projects for search scoping
```

On first run, watsup prompts for your Tempo token, Jira credentials, and starred project keys. These are cached in `~/.config/watsup/config.sexp`.

For each Watson project entry, you're prompted to assign a Jira ticket via interactive search:

```
coding - 1h 30m
  Search Jira [coding]: metric
  1) DEV-101  Metric input validation
  2) DEV-205  Metric dashboard
  Select [1-2], new search, [n] skip, [S] skip always: 1
  Description for DEV-101 (optional): implement auth flow
```

The search is scoped to your starred projects, tickets you've touched, and recently closed issues. Tags that look like ticket IDs (e.g. `DEV-101`) are looked up directly against Jira.

If the entry has Watson tags, you can split it into per-tag worklogs:

```
cr - 50m
  [PROJ-202  35m]
  [LOG-303  15m]
  [ticket] assign all | [s] split by tags | [n] skip | [S] skip always: s
  [PROJ-202  35m] Search Jira [PROJ-202]: (Enter to look up PROJ-202)
  Description for PROJ-202 (optional): Code review
  [LOG-303  15m] Search Jira [LOG-303]: (Enter to look up LOG-303)
  Description for LOG-303 (optional):
```

After all entries are processed, watsup shows a summary and asks for confirmation before posting:

```
=== Summary ===
Post:
  DEV-101    (1h 30m)  [Development]  coding  "implement auth flow"
  PROJ-202   (   35m)  [Development]  cr:PROJ-202  "Code review"
  LOG-303    (   15m)                 cr:LOG-303
Skip:
  breaks     (   45m)

[Enter] post | [n] skip day:
```

### Caching

Ticket assignments are remembered per project (and per `project:tag` for splits). On subsequent runs, cached entries show their current mapping with the option to keep, change, or skip.

Date ranges are processed one day at a time, each with its own summary and confirmation. Skipping a day continues to the next.
