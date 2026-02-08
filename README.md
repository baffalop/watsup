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
```

On first run, watsup prompts for your Tempo token and Jira credentials. These are cached in `~/.config/watsup/config.sexp`.

For each Watson project entry, you're prompted to assign a Jira ticket:

```
coding - 1h 30m
  [ticket] assign | [n] skip | [S] skip always: DEV-101
  Description for DEV-101 (optional): implement auth flow
```

If the entry has Watson tags, you can split it into per-tag worklogs:

```
cr - 50m
  [PROJ-202  35m]
  [LOG-303  15m]
  [ticket] assign all | [s] split by tags | [n] skip | [S] skip always: s
  [PROJ-202  35m] [ticket] assign | [n] skip: PROJ-202
  Description for PROJ-202 (optional): Code review
  [LOG-303  15m] [ticket] assign | [n] skip:
  Description for LOG-303 (optional):
```

(Tags that look like ticket IDs are auto-accepted when you press Enter.)

After all entries are processed, watsup shows a summary and asks for confirmation before posting:

```
--- Worklogs to post for 2026-02-05 ---
  DEV-101: 1h 30m - implement auth flow
  PROJ-202:    35m - review PR
  LOG-303:    15m
  (skipped: breaks 45m)

[Enter] post | [n] skip day:
```

### Caching

Ticket assignments are remembered per project. On subsequent runs:

- **Ticket** mappings auto-assign without prompting
- **Skip** mappings are silently skipped (but listed at the end)
- **Auto-extract** mappings (from split where all tags were ticket IDs) automatically extract tickets from tags

Date ranges are processed one day at a time, each with its own summary and confirmation. Skipping a day continues to the next.
