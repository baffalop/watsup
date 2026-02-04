# Watsup Development Guide

## Getting Started

```bash
# Install dependencies (uses local opam switch)
opam install . --deps-only

# Build
opam exec -- dune build

# Run tests
opam exec -- dune runtest

# Run the CLI
opam exec -- dune exec watsup
```

**Important:** Always use `opam exec -- dune` for all dune commands. The local opam switch won't be in PATH otherwise.

## Style Guide

### Operator Preferences

Prefer `@@` over parentheses for function application:

```ocaml
(* Good *)
io.output @@ sprintf "Result: %d\n" result

(* Avoid *)
io.output (sprintf "Result: %d\n" result)
```

Use `|>` pipeline style for chained operations:

```ocaml
(* Good *)
List.map entries ~f:process
|> List.filter ~f:is_valid
|> List.iter ~f:print

(* Avoid *)
List.iter ~f:print (List.filter ~f:is_valid (List.map entries ~f:process))
```

### Pattern Matching

Use explicit patterns instead of wildcards where possible:

```ocaml
(* Good - compiler-checked exhaustiveness *)
List.iter posts ~f:(function
  | Processor.Post { ticket; duration; source } -> handle_post ticket duration source
  | Processor.Skip _ -> ())

(* Avoid - hides potential bugs *)
List.iter posts ~f:(function
  | Processor.Post { ticket; duration; source } -> handle_post ticket duration source
  | _ -> ())
```

### Module Conventions

- Use `{ config with field = value }` for immutable updates
- Expose minimal interface in `.mli` files
- Use `[@@deriving sexp]` for config types
- Use Core library functions throughout

## Testing Philosophy

### Three Levels of Testing

```
┌─────────────────────────────────────────────────────────────────┐
│                    Manual CLI Testing                           │
│              (final verification with real IO)                  │
│                  ./scripts/test-cli.sh                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      E2E Tests                                  │
│           (full flow with mocked IO, in test/test_e2e.ml)       │
│              opam exec -- dune runtest                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Unit Tests                                  │
│        (inline expect tests in lib/*.ml modules)                │
│              opam exec -- dune runtest                          │
└─────────────────────────────────────────────────────────────────┘
```

### Unit Tests (Inline, TDD in the Small)

Pure functions get inline `%expect_test` blocks in their module:

```ocaml
(* In lib/processor.ml *)
let%expect_test "process_entry with cached ticket" =
  let entry = { Watson.project = "myproj"; total = Duration.of_hms ~hours:1 ~mins:28 ~secs:0; tags = [] } in
  let decisions, mapping = process_entry
    ~entry
    ~cached:(Some (Config.Ticket "PROJ-123"))
    ~prompt:(fun _ -> failwith "should not prompt") in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Post ((ticket PROJ-123) (duration 5400) (source myproj)))) |}]
```

### E2E Tests (TDD in the Large)

Full workflow tests with mocked IO in `test/test_e2e.ml`:

```ocaml
let%expect_test "posts worklogs with mocked HTTP" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = { ... } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let io, get_output = make_io
      ~inputs:["test work"; ""]  (* description, Enter to confirm *)
      ~http_post_responses:[{ Io.status = 200; body = "{}" }]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path;
    print_string @@ normalize_output ~config_path (get_output ()));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
    ...
    Posted 1/1 worklogs
  |}]
```

### Manual Testing (Final Verification)

Use `scripts/test-cli.sh` for real CLI testing:

```bash
# Run with isolated test config (won't affect real config)
./scripts/test-cli.sh

# Run with real config (for API testing)
./scripts/test-cli.sh real

# Clean test config
./scripts/test-cli.sh clean

# Token management tests
./scripts/test-cli.sh token
```

## Expect Test Workflow

**Never manually type expected output.** Follow this workflow:

1. **Write test with empty expect block:**
   ```ocaml
   let%expect_test "my test" =
     (* test code *)
     print_string result;
     [%expect {||}]
   ```

2. **Run tests to see proposed output:**
   ```bash
   opam exec -- dune runtest
   ```

3. **Review the diff** - if output looks correct:
   ```bash
   opam exec -- dune promote
   ```

4. **Run tests again to verify:**
   ```bash
   opam exec -- dune runtest
   ```

## Best Practices

### Dependency Injection

All external IO goes through `Io.t`:

```ocaml
type t = {
  input : unit -> string;
  input_secret : unit -> string;  (* hidden input for tokens *)
  output : string -> unit;
  run_command : string -> string;
  http_post : url:string -> headers:(string * string) list -> body:string -> http_response Lwt.t;
  http_get : url:string -> headers:(string * string) list -> http_response Lwt.t;
}
```

In production, use `Io.stdio`. In tests, use `Io.create` with mocks:

```ocaml
let io = Io.create
  ~input:(fun () -> Queue.dequeue_exn input_queue)
  ~input_secret:(fun () -> Queue.dequeue_exn input_queue)
  ~output:(fun s -> Buffer.add_string buf s)
  ~run_command:(fun _cmd -> mocked_watson_output)
  ~http_post:(fun ~url:_ ~headers:_ ~body:_ -> Lwt.return { status = 200; body = "{}" })
  ~http_get:(fun ~url:_ ~headers:_ -> Lwt.return { status = 200; body = "{}" })
```

### Error Handling

- Use `Or_error.t` for recoverable errors
- Use `failwith` for programming errors / unrecoverable states
- Always show response body on HTTP failures for debugging:

```ocaml
if success then
  io.output @@ sprintf "%s: OK\n" ticket
else begin
  io.output @@ sprintf "%s: FAILED (%d)\n" ticket response.status;
  io.output @@ sprintf "  Response: %s\n" response.body
end
```

### Config Evolution

When adding new config fields, use `[@default]` for backwards compatibility:

```ocaml
type t = {
  tempo_token : string [@default ""];
  jira_token : string [@default ""];
  (* ... *)
}
[@@deriving sexp]
```

This allows old config files to load without errors.

### Test Coverage Checklist

For each new feature, ensure:

- [ ] Unit test for pure logic (inline in module)
- [ ] E2E test for happy path
- [ ] E2E test for error cases
- [ ] Manual verification with `./scripts/test-cli.sh`

## Project Structure

```
watsup/
├── bin/
│   └── main.ml              # Entry point (thin wrapper)
├── lib/
│   ├── config.ml/mli        # Configuration persistence
│   ├── duration.ml/mli      # Time duration handling
│   ├── io.ml/mli            # IO abstraction
│   ├── main_logic.ml/mli    # Main workflow orchestration
│   ├── processor.ml/mli     # Entry processing logic
│   ├── ticket.ml/mli        # Ticket ID extraction
│   ├── watson.ml/mli        # Watson output parsing
│   └── dune                  # Library build config
├── test/
│   ├── test_e2e.ml          # E2E tests
│   └── dune                  # Test build config
├── scripts/
│   └── test-cli.sh          # Manual testing helper
├── docs/
│   ├── overview.md          # Architecture overview
│   ├── development-guide.md # This file
│   └── plans/               # Implementation plans
└── dune-project             # Dune project config
```

## Debugging Tips

### HTTP Issues

Run with real config to see actual API responses:

```bash
./scripts/test-cli.sh real
```

Error responses include the full body for debugging.

### Config Issues

Check your config file:

```bash
cat ~/.config/watsup/config.sexp
```

For testing, use isolated config:

```bash
./scripts/test-cli.sh clean
./scripts/test-cli.sh
```

### Watson Parsing

Watson output varies by version. If parsing fails, capture the raw output:

```bash
watson report -dG > watson-output.txt
```

Then write a test with that exact output.
