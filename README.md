# Watsup

An interactive tool to post your [Watson](https://github.com/jazzband/watson) logs to [Jira Tempo](https://tempo.io/).

Built with OCaml (and Claude Code, with thanks to [obra](https://github.com/obra/superpowers)).

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

[TODO]
