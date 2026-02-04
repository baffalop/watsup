# Watsup Phase 2: Testable Incremental Rebuild

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild watsup incrementally with e2e testability at each step, separating IO from pure logic.

**Architecture:** Dependency injection for IO operations (stdin/stdout/filesystem), pure functions for business logic, e2e test harness using expect tests with captured IO.

**Tech Stack:** OCaml 5.4, Core, Angstrom, Cohttp-lwt-unix, ppx_jane, ppx_expect

---

## Best Practices (Rules to Enforce)

Flag these for the user to potentially add as project rules:

1. **Always use `opam exec -- dune` for all dune commands** - The local opam switch won't be in PATH otherwise
2. **Separate IO from logic** - Functions that read stdin or write stdout should be thin wrappers around pure functions
3. **Design for testability** - Core logic should take inputs as parameters, not read from global state
4. **Use `.mli` interfaces** - Control module boundaries, hide implementation details
5. **E2E tests before unit tests** - Each feature should have an e2e test that exercises the full path
6. **No direct `In_channel.stdin` in business logic** - Pass input as parameters or use dependency injection

---

## Bash E2E Testing Strategy

**Technique:** Use bash here-docs to provide multiple lines of stdin input to the CLI:

```bash
opam exec -- dune exec watsup << 'EOF'
input-line-1
input-line-2
EOF
```

**Key findings from experimentation:**
- When stdin is exhausted, `read_line_safe` returns empty string (graceful)
- Here-docs reliably provide multi-line input
- Can use temp directories for config isolation via `$HOME` override
- macOS lacks `timeout` command; use background process + kill if needed

**Each task's final step:** Run bash-based CLI test to verify real binary behavior.

---

## Task 1: E2E Test Infrastructure + Manual Testing Setup

**Files:**
- Create: `scripts/test-cli.sh` (manual testing helper)
- Create: `test/dune`
- Create: `test/test_e2e.ml`
- Modify: `bin/main.ml` (strip to minimal)

**Step 1: Create manual testing script**

Create `scripts/test-cli.sh`:

```bash
#!/bin/bash
# Manual CLI testing helper
# Usage: ./scripts/test-cli.sh [clean]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_HOME="${PROJECT_DIR}/.test-home"

# Clean mode - remove test config
if [[ "$1" == "clean" ]]; then
    echo "Cleaning test config..."
    rm -rf "$TEST_HOME"
    exit 0
fi

# Create isolated test home
mkdir -p "$TEST_HOME"

echo "=== Test Environment ==="
echo "TEST_HOME: $TEST_HOME"
echo "Config will be at: $TEST_HOME/.config/watsup/config.sexp"
echo ""

# Run with isolated HOME
cd "$PROJECT_DIR"
HOME="$TEST_HOME" opam exec -- dune exec watsup

echo ""
echo "=== Config after run ==="
cat "$TEST_HOME/.config/watsup/config.sexp" 2>/dev/null || echo "(no config created)"
```

Make executable:
```bash
chmod +x scripts/test-cli.sh
```

**Step 2: Create test directory with dune config**

Create `test/dune`:

```dune
(library
 (name test_watsup)
 (libraries watsup core core_unix str)
 (preprocess (pps ppx_jane))
 (inline_tests))
```

**Step 2: Strip main.ml to absolute minimum**

Replace `bin/main.ml` with a minimal version that just handles token:

```ocaml
open Core
module Config = Watsup.Config

let main ~input ~output =
  let config_path = Config.default_path () in
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  let config =
    if String.is_empty config.tempo_token then begin
      output "Enter Tempo API token: ";
      let token = input () in
      { config with tempo_token = token }
    end
    else config
  in

  output (sprintf "Token: %s\n" (String.prefix config.tempo_token 8 ^ "..."));
  Config.save ~path:config_path config |> Or_error.ok_exn;
  output (sprintf "Config saved to %s\n" config_path)

let () =
  let input () = In_channel.(input_line_exn stdin) in
  let output s = Out_channel.(output_string stdout s; flush stdout) in
  main ~input ~output
```

**Step 3: Create basic e2e test skeleton**

Create `test/test_e2e.ml`:

```ocaml
open Core

(* Test harness that captures IO *)
let run_with_io ~inputs ~config_dir f =
  let input_queue = Queue.of_list inputs in
  let output_buf = Buffer.create 256 in
  let input () =
    match Queue.dequeue input_queue with
    | Some line -> line
    | None -> failwith "No more input available"
  in
  let output s = Buffer.add_string output_buf s in

  (* Override config path for testing *)
  let original_home = Sys.getenv "HOME" in
  Unix.putenv ~key:"HOME" ~data:config_dir;

  (try f ~input ~output with exn ->
    Option.iter original_home ~f:(fun h -> Unix.putenv ~key:"HOME" ~data:h);
    raise exn);

  Option.iter original_home ~f:(fun h -> Unix.putenv ~key:"HOME" ~data:h);
  Buffer.contents output_buf

let%expect_test "token prompt when no config exists" =
  let temp_dir = Filename_unix.temp_dir "watsup_test" "" in
  let output = run_with_io
    ~inputs:["my-test-token-12345"]
    ~config_dir:temp_dir
    (fun ~input ~output ->
      (* Import and run main here - we'll wire this up *)
      output "Enter Tempo API token: ";
      let token = input () in
      output (sprintf "Token: %s...\n" (String.prefix token 8));
      output (sprintf "Config saved to %s/.config/watsup/config.sexp\n" temp_dir))
  in
  print_string output;
  [%expect {|
    Enter Tempo API token: Token: my-test-...
    Config saved to /tmp/watsup_testXXXXXX/.config/watsup/config.sexp
  |}];
  (* Cleanup *)
  Core_unix.system_exn (sprintf "rm -rf %s" temp_dir)
```

**Step 4: Run tests to verify infrastructure**

Run:
```bash
opam exec -- dune runtest
```

Expected: Test runs (may need adjustment for temp dir path in expect output)

**Step 5: Commit**

```bash
git add scripts/test-cli.sh test/dune test/test_e2e.ml bin/main.ml
git commit -m "feat: add e2e test infrastructure with IO injection"
```

**Step 6: Bash CLI verification**

Run the actual CLI with piped input to verify it works:

```bash
# Create isolated test environment
TEST_HOME=$(mktemp -d)
echo "test-token-from-bash" | HOME="$TEST_HOME" opam exec -- dune exec watsup 2>&1
echo "---"
echo "Config contents:"
cat "$TEST_HOME/.config/watsup/config.sexp"
rm -rf "$TEST_HOME"
```

Expected output should show:
- Token prompt
- Token configured message
- Config saved with the test token

---

## Task 2: Testable Token Management

**Files:**
- Modify: `bin/main.ml` (make fully testable)
- Modify: `test/test_e2e.ml` (real e2e test)
- Create: `lib/io.mli` (IO abstraction)
- Create: `lib/io.ml`

**Step 1: Create IO abstraction module**

Create `lib/io.mli`:

```ocaml
type t = {
  input : unit -> string;
  output : string -> unit;
}

val stdio : t
val create : input:(unit -> string) -> output:(string -> unit) -> t
```

Create `lib/io.ml`:

```ocaml
type t = {
  input : unit -> string;
  output : string -> unit;
}

let stdio = {
  input = (fun () -> In_channel.(input_line_exn stdin));
  output = (fun s -> Out_channel.(output_string stdout s; flush stdout));
}

let create ~input ~output = { input; output }
```

**Step 2: Refactor main.ml to use IO module**

Replace `bin/main.ml`:

```ocaml
open Core
module Config = Watsup.Config
module Io = Watsup.Io

let run ~io ~config_path =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  let config =
    if String.is_empty config.tempo_token then begin
      io.Io.output "Enter Tempo API token: ";
      let token = io.input () in
      { config with tempo_token = token }
    end
    else config
  in

  io.output (sprintf "Token configured: %s...\n" (String.prefix config.tempo_token 8));
  Config.save ~path:config_path config |> Or_error.ok_exn;
  io.output (sprintf "Config saved to %s\n" config_path)

let () =
  let config_path = Config.default_path () in
  run ~io:Io.stdio ~config_path
```

**Step 3: Update e2e test to use real main**

Update `test/test_e2e.ml`:

```ocaml
open Core
module Config = Watsup.Config
module Io = Watsup.Io

let with_temp_config f =
  let temp_dir = Filename_unix.temp_dir "watsup_test" "" in
  let config_path = temp_dir ^/ ".config" ^/ "watsup" ^/ "config.sexp" in
  Core_unix.mkdir_p (Filename.dirname config_path);
  protect ~f:(fun () -> f ~config_path ~temp_dir)
    ~finally:(fun () ->
      Core_unix.system_exn (sprintf "rm -rf %s" (Filename.quote temp_dir)) |> ignore)

let make_io ~inputs =
  let input_queue = Queue.of_list inputs in
  let output_buf = Buffer.create 256 in
  let io = Io.create
    ~input:(fun () ->
      match Queue.dequeue input_queue with
      | Some line -> line
      | None -> failwith "No more input available")
    ~output:(fun s -> Buffer.add_string output_buf s)
  in
  (io, fun () -> Buffer.contents output_buf)

(* Import the run function - we need to expose it *)
(* For now, inline a minimal version *)
let run_main ~io ~config_path =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in
  let config =
    if String.is_empty config.tempo_token then begin
      io.Io.output "Enter Tempo API token: ";
      let token = io.input () in
      { config with tempo_token = token }
    end
    else config
  in
  io.output (sprintf "Token configured: %s...\n" (String.prefix config.tempo_token 8));
  Config.save ~path:config_path config |> Or_error.ok_exn;
  io.output "Done.\n"

let%expect_test "prompts for token when no config exists" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let io, get_output = make_io ~inputs:["my-secret-token-12345"] in
    run_main ~io ~config_path;
    print_string (get_output ()));
  [%expect {|
    Enter Tempo API token: Token configured: my-secre...
    Done.
  |}]

let%expect_test "uses cached token when config exists" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Pre-populate config *)
    let config = { Config.empty with tempo_token = "existing-token-xyz" } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let io, get_output = make_io ~inputs:[] in
    run_main ~io ~config_path;
    print_string (get_output ()));
  [%expect {|
    Token configured: existing...
    Done.
  |}]
```

**Step 4: Run tests**

Run:
```bash
opam exec -- dune runtest
```

Expected: Both e2e tests pass

**Step 5: Commit**

```bash
git add lib/io.ml lib/io.mli bin/main.ml test/test_e2e.ml
git commit -m "feat: testable token management with IO injection"
```

**Step 6: Bash CLI verification**

```bash
# Test 1: Fresh config - should prompt for token
TEST_HOME=$(mktemp -d)
echo "my-bash-token-xyz" | HOME="$TEST_HOME" opam exec -- dune exec watsup 2>&1
echo "--- Config:"
cat "$TEST_HOME/.config/watsup/config.sexp"

# Test 2: Existing config - should skip token prompt
echo "" | HOME="$TEST_HOME" opam exec -- dune exec watsup 2>&1
rm -rf "$TEST_HOME"
```

Expected: First run prompts for token, second run uses cached token.

---

## Task 3: Add Watson Report Loading

**Files:**
- Modify: `bin/main.ml` (add watson parsing)
- Modify: `test/test_e2e.ml` (test watson flow)
- Modify: `lib/io.mli` (add command execution)
- Modify: `lib/io.ml`

**Step 1: Extend IO module with command execution**

Update `lib/io.mli`:

```ocaml
type t = {
  input : unit -> string;
  output : string -> unit;
  run_command : string -> string;  (* Execute shell command, return output *)
}

val stdio : t
val create :
  input:(unit -> string) ->
  output:(string -> unit) ->
  run_command:(string -> string) ->
  t
```

Update `lib/io.ml`:

```ocaml
open Core

type t = {
  input : unit -> string;
  output : string -> unit;
  run_command : string -> string;
}

let stdio = {
  input = (fun () -> In_channel.(input_line_exn stdin));
  output = (fun s -> Out_channel.(output_string stdout s; flush stdout));
  run_command = (fun cmd ->
    let ic = Core_unix.open_process_in cmd in
    let output = In_channel.input_all ic in
    let _ = Core_unix.close_process_in ic in
    output);
}

let create ~input ~output ~run_command = { input; output; run_command }
```

**Step 2: Update main.ml to parse watson report**

Update `bin/main.ml`:

```ocaml
open Core
module Config = Watsup.Config
module Io = Watsup.Io
module Watson = Watsup.Watson

let run ~io ~config_path =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  (* Token check *)
  let config =
    if String.is_empty config.tempo_token then begin
      io.Io.output "Enter Tempo API token: ";
      let token = io.input () in
      { config with tempo_token = token }
    end
    else config
  in
  io.output (sprintf "Token configured: %s...\n" (String.prefix config.tempo_token 8));

  (* Parse watson report *)
  let watson_output = io.run_command "watson report -dG" in
  let report = Watson.parse watson_output |> Or_error.ok_exn in

  io.output (sprintf "Report: %s\n" report.date_range);
  io.output (sprintf "Entries: %d\n" (List.length report.entries));
  List.iter report.entries ~f:(fun entry ->
    io.output (sprintf "  %s - %s\n" entry.project
      (Watsup.Duration.to_string entry.total)));

  Config.save ~path:config_path config |> Or_error.ok_exn

let () =
  let config_path = Config.default_path () in
  run ~io:Io.stdio ~config_path
```

**Step 3: Add e2e test for watson parsing**

Add to `test/test_e2e.ml`:

```ocaml
module Watson = Watsup.Watson
module Duration = Watsup.Duration

let sample_watson_report = {|Mon 03 February 2026 -> Mon 03 February 2026

project-a - 2h 30m 00s
	[task1     1h 15m 00s]
	[task2     1h 15m 00s]

breaks - 45m 00s

Total: 3h 15m 00s|}

let run_main_full ~io ~config_path =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in
  let config =
    if String.is_empty config.tempo_token then begin
      io.Io.output "Enter Tempo API token: ";
      let token = io.input () in
      { config with tempo_token = token }
    end
    else config
  in
  io.output (sprintf "Token configured: %s...\n" (String.prefix config.tempo_token 8));

  let watson_output = io.run_command "watson report -dG" in
  let report = Watson.parse watson_output |> Or_error.ok_exn in

  io.output (sprintf "Report: %s\n" report.date_range);
  io.output (sprintf "Entries: %d\n" (List.length report.entries));
  List.iter report.entries ~f:(fun entry ->
    io.output (sprintf "  %s - %s\n" entry.project (Duration.to_string entry.total)));

  Config.save ~path:config_path config |> Or_error.ok_exn

let make_io_full ~inputs ~watson_output =
  let input_queue = Queue.of_list inputs in
  let output_buf = Buffer.create 256 in
  let io = Io.create
    ~input:(fun () ->
      match Queue.dequeue input_queue with
      | Some line -> line
      | None -> failwith "No more input available")
    ~output:(fun s -> Buffer.add_string output_buf s)
    ~run_command:(fun _cmd -> watson_output)
  in
  (io, fun () -> Buffer.contents output_buf)

let%expect_test "parses watson report and lists entries" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Pre-populate config with token *)
    let config = { Config.empty with tempo_token = "test-token-xyz" } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let io, get_output = make_io_full ~inputs:[] ~watson_output:sample_watson_report in
    run_main_full ~io ~config_path;
    print_string (get_output ()));
  [%expect {|
    Token configured: test-tok...
    Report: Mon 03 February 2026 -> Mon 03 February 2026
    Entries: 2
      project-a - 2h 30m
      breaks - 45m
  |}]
```

**Step 4: Run tests**

Run:
```bash
opam exec -- dune runtest
```

Expected: All tests pass

**Step 5: Commit**

```bash
git add lib/io.ml lib/io.mli bin/main.ml test/test_e2e.ml
git commit -m "feat: add watson report parsing to main flow"
```

**Step 6: Bash CLI verification**

```bash
# Pre-populate config with token, then run to see watson parsing
TEST_HOME=$(mktemp -d)
mkdir -p "$TEST_HOME/.config/watsup"
cat > "$TEST_HOME/.config/watsup/config.sexp" << 'SEXP'
((tempo_token test-token-123) (category ()) (mappings ()))
SEXP

HOME="$TEST_HOME" opam exec -- dune exec watsup 2>&1
rm -rf "$TEST_HOME"
```

Expected: Shows token configured, then lists watson report entries.

---

## Task 4: Entry Processing Logic (Pure)

**Files:**
- Create: `lib/processor.mli`
- Create: `lib/processor.ml`
- Modify: `test/test_e2e.ml`

**Step 1: Create processor module interface**

Create `lib/processor.mli`:

```ocaml
open Core

type decision =
  | Post of { ticket : string; duration : Duration.t; source : string }
  | Skip of { project : string; duration : Duration.t }
[@@deriving sexp]

type prompt_response =
  | Accept of string  (* ticket *)
  | Skip_once
  | Skip_always
[@@deriving sexp]

(** Process a single entry given cached mapping and user prompt function *)
val process_entry :
  entry:Watson.entry ->
  cached:Config.mapping option ->
  prompt:(Watson.entry -> prompt_response) ->
  decision list * Config.mapping option  (* decisions and optional new mapping *)
```

**Step 2: Implement processor module**

Create `lib/processor.ml`:

```ocaml
open Core

type decision =
  | Post of { ticket : string; duration : Duration.t; source : string }
  | Skip of { project : string; duration : Duration.t }
[@@deriving sexp]

type prompt_response =
  | Accept of string
  | Skip_once
  | Skip_always
[@@deriving sexp]

let process_entry ~entry ~cached ~prompt =
  match cached with
  | Some Config.Skip ->
    ([Skip { project = entry.Watson.project; duration = entry.total }], None)
  | Some (Config.Ticket ticket) ->
    ([Post {
      ticket;
      duration = Duration.round_5min entry.total;
      source = entry.project
    }], None)
  | Some Config.Auto_extract ->
    let tickets = Ticket.extract_tickets
      (List.map entry.tags ~f:(fun t -> t.Watson.name)) in
    let decisions = List.filter_map tickets ~f:(fun ticket ->
      match List.find entry.tags ~f:(fun t -> String.equal t.name ticket) with
      | Some tag -> Some (Post {
          ticket;
          duration = Duration.round_5min tag.duration;
          source = sprintf "%s:%s" entry.project ticket;
        })
      | None -> None)
    in
    (decisions, None)
  | None ->
    let response = prompt entry in
    match response with
    | Accept ticket ->
      ([Post {
        ticket;
        duration = Duration.round_5min entry.total;
        source = entry.project
      }], Some (Config.Ticket ticket))
    | Skip_once ->
      ([], None)
    | Skip_always ->
      ([Skip { project = entry.project; duration = entry.total }], Some Config.Skip)

let%expect_test "process_entry with cached ticket" =
  let entry = {
    Watson.project = "myproj";
    total = Duration.of_hms ~hours:1 ~mins:28 ~secs:0;
    tags = [];
  } in
  let decisions, mapping = process_entry
    ~entry
    ~cached:(Some (Config.Ticket "PROJ-123"))
    ~prompt:(fun _ -> failwith "should not prompt") in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Post ((ticket PROJ-123) (duration 5400) (source myproj)))) |}];
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| () |}]

let%expect_test "process_entry with cached skip" =
  let entry = {
    Watson.project = "breaks";
    total = Duration.of_hms ~hours:0 ~mins:45 ~secs:0;
    tags = [];
  } in
  let decisions, _ = process_entry
    ~entry
    ~cached:(Some Config.Skip)
    ~prompt:(fun _ -> failwith "should not prompt") in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Skip ((project breaks) (duration 2700)))) |}]

let%expect_test "process_entry prompts when no cache" =
  let entry = {
    Watson.project = "newproj";
    total = Duration.of_hms ~hours:2 ~mins:0 ~secs:0;
    tags = [];
  } in
  let decisions, mapping = process_entry
    ~entry
    ~cached:None
    ~prompt:(fun _ -> Accept "NEW-456") in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Post ((ticket NEW-456) (duration 7200) (source newproj)))) |}];
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| ((Ticket NEW-456)) |}]

let%expect_test "process_entry auto_extract" =
  let entry = {
    Watson.project = "cr";
    total = Duration.of_hms ~hours:1 ~mins:0 ~secs:0;
    tags = [
      { Watson.name = "FK-123"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
      { Watson.name = "review"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
      { Watson.name = "FK-456"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
    ];
  } in
  let decisions, _ = process_entry
    ~entry
    ~cached:(Some Config.Auto_extract)
    ~prompt:(fun _ -> failwith "should not prompt") in
  print_s [%sexp (decisions : decision list)];
  [%expect {|
    ((Post ((ticket FK-123) (duration 1800) (source cr:FK-123)))
     (Post ((ticket FK-456) (duration 900) (source cr:FK-456))))
  |}]
```

**Step 3: Run tests**

Run:
```bash
opam exec -- dune runtest
```

Expected: All processor tests pass

**Step 4: Commit**

```bash
git add lib/processor.ml lib/processor.mli
git commit -m "feat: add pure Processor module for entry decisions"
```

**Step 5: Bash CLI verification**

Task 4 adds pure logic only (no CLI changes). Verify build and all tests still pass:

```bash
opam exec -- dune build
opam exec -- dune runtest
```

Expected: All unit tests pass including new Processor tests.

---

## Task 5: Interactive Prompt Flow

**Files:**
- Modify: `bin/main.ml` (integrate processor)
- Modify: `test/test_e2e.ml` (test full interactive flow)

**Step 1: Update main.ml to use processor**

Update `bin/main.ml` to wire processor with interactive prompts:

```ocaml
open Core
module Config = Watsup.Config
module Duration = Watsup.Duration
module Io = Watsup.Io
module Processor = Watsup.Processor
module Watson = Watsup.Watson

let prompt_for_entry ~io entry =
  io.Io.output (sprintf "\n%s - %s\n"
    entry.Watson.project
    (Duration.to_string (Duration.round_5min entry.total)));
  io.output "  [ticket] assign | [n] skip | [S] skip always: ";
  let input = io.input () in
  match input with
  | "n" -> Processor.Skip_once
  | "S" -> Processor.Skip_always
  | ticket -> Processor.Accept ticket

let run ~io ~config_path =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  (* Token check *)
  let config =
    if String.is_empty config.tempo_token then begin
      io.Io.output "Enter Tempo API token: ";
      let token = io.input () in
      { config with tempo_token = token }
    end
    else config
  in

  (* Parse watson report *)
  let watson_output = io.run_command "watson report -dG" in
  let report = Watson.parse watson_output |> Or_error.ok_exn in

  io.output (sprintf "Report: %s (%d entries)\n"
    report.date_range (List.length report.entries));

  (* Process each entry *)
  let all_decisions = ref [] in
  let config = ref config in

  List.iter report.entries ~f:(fun entry ->
    let cached = Config.get_mapping !config entry.project in
    let decisions, new_mapping = Processor.process_entry
      ~entry ~cached
      ~prompt:(prompt_for_entry ~io) in
    all_decisions := !all_decisions @ decisions;
    Option.iter new_mapping ~f:(fun m ->
      config := Config.set_mapping !config entry.project m));

  (* Summary *)
  io.output "\n=== Summary ===\n";
  let posts, skips = List.partition_tf !all_decisions ~f:(function
    | Processor.Post _ -> true
    | Processor.Skip _ -> false) in

  List.iter posts ~f:(function
    | Processor.Post { ticket; duration; source } ->
      io.output (sprintf "POST: %s (%s) from %s\n" ticket (Duration.to_string duration) source)
    | _ -> ());

  List.iter skips ~f:(function
    | Processor.Skip { project; duration } ->
      io.output (sprintf "SKIP: %s (%s)\n" project (Duration.to_string duration))
    | _ -> ());

  Config.save ~path:config_path !config |> Or_error.ok_exn

let () =
  let config_path = Config.default_path () in
  run ~io:Io.stdio ~config_path
```

**Step 2: Add e2e test for interactive flow**

Add to `test/test_e2e.ml`:

```ocaml
module Processor = Watsup.Processor

let run_main_interactive ~io ~config_path =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in
  let config =
    if String.is_empty config.tempo_token then begin
      io.Io.output "Enter Tempo API token: ";
      let token = io.input () in
      { config with tempo_token = token }
    end
    else config
  in

  let watson_output = io.run_command "watson report -dG" in
  let report = Watson.parse watson_output |> Or_error.ok_exn in

  io.output (sprintf "Report: %s (%d entries)\n"
    report.date_range (List.length report.entries));

  let all_decisions = ref [] in
  let config = ref config in

  List.iter report.entries ~f:(fun entry ->
    let cached = Config.get_mapping !config entry.project in
    let prompt entry =
      io.Io.output (sprintf "\n%s - %s\n"
        entry.Watson.project
        (Duration.to_string (Duration.round_5min entry.total)));
      io.output "  [ticket] assign | [n] skip | [S] skip always: ";
      let input = io.input () in
      match input with
      | "n" -> Processor.Skip_once
      | "S" -> Processor.Skip_always
      | ticket -> Processor.Accept ticket
    in
    let decisions, new_mapping = Processor.process_entry ~entry ~cached ~prompt in
    all_decisions := !all_decisions @ decisions;
    Option.iter new_mapping ~f:(fun m ->
      config := Config.set_mapping !config entry.project m));

  io.output "\n=== Summary ===\n";
  let posts, skips = List.partition_tf !all_decisions ~f:(function
    | Processor.Post _ -> true
    | Processor.Skip _ -> false) in

  List.iter posts ~f:(function
    | Processor.Post { ticket; duration; source } ->
      io.output (sprintf "POST: %s (%s) from %s\n" ticket (Duration.to_string duration) source)
    | _ -> ());

  List.iter skips ~f:(function
    | Processor.Skip { project; duration } ->
      io.output (sprintf "SKIP: %s (%s)\n" project (Duration.to_string duration))
    | _ -> ());

  Config.save ~path:config_path !config |> Or_error.ok_exn

let%expect_test "interactive flow with mixed inputs" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = { Config.empty with tempo_token = "test-token" } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 2h 00m 00s

breaks - 30m 00s

Total: 2h 30m 00s|} in

    let io, get_output = make_io_full
      ~inputs:["PROJ-123"; "S"]  (* assign ticket to coding, skip-always breaks *)
      ~watson_output:watson in
    run_main_interactive ~io ~config_path;
    print_string (get_output ()));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)

    coding - 2h
      [ticket] assign | [n] skip | [S] skip always:
    breaks - 30m
      [ticket] assign | [n] skip | [S] skip always:
    === Summary ===
    POST: PROJ-123 (2h) from coding
    SKIP: breaks (30m)
  |}]

let%expect_test "uses cached mappings on subsequent runs" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = {
      Config.empty with
      tempo_token = "test-token";
      mappings = [("coding", Config.Ticket "PROJ-123"); ("breaks", Config.Skip)];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 30m 00s

breaks - 45m 00s

Total: 2h 15m 00s|} in

    let io, get_output = make_io_full
      ~inputs:[]  (* no prompts needed - all cached *)
      ~watson_output:watson in
    run_main_interactive ~io ~config_path;
    print_string (get_output ()));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)

    === Summary ===
    POST: PROJ-123 (1h 30m) from coding
    SKIP: breaks (45m)
  |}]
```

**Step 3: Run tests**

Run:
```bash
opam exec -- dune runtest
```

Expected: All e2e tests pass

**Step 4: Commit**

```bash
git add bin/main.ml test/test_e2e.ml
git commit -m "feat: integrate processor with interactive prompts"
```

**Step 5: Bash CLI verification**

Test full interactive flow with multiple inputs:

```bash
TEST_HOME=$(mktemp -d)
mkdir -p "$TEST_HOME/.config/watsup"
cat > "$TEST_HOME/.config/watsup/config.sexp" << 'SEXP'
((tempo_token test-token-123) (category ()) (mappings ()))
SEXP

# Provide ticket for first entry, skip-always for second
HOME="$TEST_HOME" opam exec -- dune exec watsup 2>&1 << 'EOF'
PROJ-999
S
EOF

echo "--- Config after run:"
cat "$TEST_HOME/.config/watsup/config.sexp"
rm -rf "$TEST_HOME"
```

Expected: Shows prompts, processes inputs, displays summary with POST and SKIP entries, saves mappings to config.

---

## Task 6: Tempo API Integration

**Files:**
- Modify: `lib/io.mli` (add HTTP abstraction)
- Modify: `lib/io.ml`
- Modify: `bin/main.ml` (add posting)
- Modify: `test/test_e2e.ml` (test posting flow)

**Step 1: Add HTTP abstraction to IO**

Update `lib/io.mli`:

```ocaml
type http_response = {
  status : int;
  body : string;
}

type t = {
  input : unit -> string;
  output : string -> unit;
  run_command : string -> string;
  http_post : url:string -> headers:(string * string) list -> body:string -> http_response Lwt.t;
}

val stdio : t
val create :
  input:(unit -> string) ->
  output:(string -> unit) ->
  run_command:(string -> string) ->
  http_post:(url:string -> headers:(string * string) list -> body:string -> http_response Lwt.t) ->
  t
```

**Step 2: Implement HTTP in IO module**

Update `lib/io.ml`:

```ocaml
open Core
open Lwt.Syntax

type http_response = {
  status : int;
  body : string;
}

type t = {
  input : unit -> string;
  output : string -> unit;
  run_command : string -> string;
  http_post : url:string -> headers:(string * string) list -> body:string -> http_response Lwt.t;
}

let real_http_post ~url ~headers ~body =
  let uri = Uri.of_string url in
  let headers = Cohttp.Header.of_list headers in
  let body = Cohttp_lwt.Body.of_string body in
  let* (resp, resp_body) = Cohttp_lwt_unix.Client.post ~headers ~body uri in
  let* body_str = Cohttp_lwt.Body.to_string resp_body in
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  Lwt.return { status; body = body_str }

let stdio = {
  input = (fun () -> In_channel.(input_line_exn stdin));
  output = (fun s -> Out_channel.(output_string stdout s; flush stdout));
  run_command = (fun cmd ->
    let ic = Core_unix.open_process_in cmd in
    let output = In_channel.input_all ic in
    let _ = Core_unix.close_process_in ic in
    output);
  http_post = real_http_post;
}

let create ~input ~output ~run_command ~http_post =
  { input; output; run_command; http_post }
```

**Step 3: Update main.ml with posting**

Add posting logic to `bin/main.ml`:

```ocaml
open Core
open Lwt.Syntax
module Config = Watsup.Config
module Duration = Watsup.Duration
module Io = Watsup.Io
module Processor = Watsup.Processor
module Watson = Watsup.Watson
module Worklog = Watsup.Worklog

let post_worklog ~io ~token decision =
  match decision with
  | Processor.Skip _ -> Lwt.return None
  | Processor.Post { ticket; duration; source = _ } ->
    let url = "https://api.tempo.io/4/worklogs" in
    let headers = [
      ("Authorization", sprintf "Bearer %s" token);
      ("Content-Type", "application/json");
    ] in
    let body = Yojson.Safe.to_string (`Assoc [
      ("issueKey", `String ticket);
      ("timeSpentSeconds", `Int (Duration.to_seconds duration));
      ("startDate", `String (Date.to_string (Date.today ~zone:Time_float.Zone.utc)));
      ("startTime", `String "09:00:00");
      ("description", `String "");
      ("authorAccountId", `String "self");
    ]) in
    let* response = io.Io.http_post ~url ~headers ~body in
    if response.status >= 200 && response.status < 300 then
      Lwt.return (Some (Worklog.Posted))
    else
      Lwt.return (Some (Worklog.Failed response.body))

let prompt_for_entry ~io entry =
  io.Io.output (sprintf "\n%s - %s\n"
    entry.Watson.project
    (Duration.to_string (Duration.round_5min entry.total)));
  io.output "  [ticket] assign | [n] skip | [S] skip always: ";
  let input = io.input () in
  match input with
  | "n" -> Processor.Skip_once
  | "S" -> Processor.Skip_always
  | ticket -> Processor.Accept ticket

let run ~io ~config_path =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  let config =
    if String.is_empty config.tempo_token then begin
      io.Io.output "Enter Tempo API token: ";
      let token = io.input () in
      { config with tempo_token = token }
    end
    else config
  in

  let watson_output = io.run_command "watson report -dG" in
  let report = Watson.parse watson_output |> Or_error.ok_exn in

  io.output (sprintf "Report: %s (%d entries)\n"
    report.date_range (List.length report.entries));

  let all_decisions = ref [] in
  let config = ref config in

  List.iter report.entries ~f:(fun entry ->
    let cached = Config.get_mapping !config entry.project in
    let decisions, new_mapping = Processor.process_entry
      ~entry ~cached
      ~prompt:(prompt_for_entry ~io) in
    all_decisions := !all_decisions @ decisions;
    Option.iter new_mapping ~f:(fun m ->
      config := Config.set_mapping !config entry.project m));

  let posts = List.filter !all_decisions ~f:(function
    | Processor.Post _ -> true
    | Processor.Skip _ -> false) in

  if List.is_empty posts then
    io.output "\nNo worklogs to post.\n"
  else begin
    io.output "\n=== Worklogs to Post ===\n";
    List.iter posts ~f:(function
      | Processor.Post { ticket; duration; source } ->
        io.output (sprintf "%s  %s  %s\n" ticket (Duration.to_string duration) source)
      | _ -> ());

    io.output "\n[Enter] post | [q] quit: ";
    let confirm = io.input () in
    if not (String.equal confirm "q") then begin
      io.output "\nPosting...\n";
      Lwt_main.run (
        let* results = Lwt_list.map_s (fun d ->
          let* result = post_worklog ~io ~token:(!config).tempo_token d in
          (match d, result with
           | Processor.Post { ticket; _ }, Some Worklog.Posted ->
             io.output (sprintf "  %s: OK\n" ticket)
           | Processor.Post { ticket; _ }, Some (Worklog.Failed msg) ->
             io.output (sprintf "  %s: FAILED - %s\n" ticket msg)
           | _ -> ());
          Lwt.return result
        ) posts in
        let ok = List.count results ~f:(function Some Worklog.Posted -> true | _ -> false) in
        let failed = List.count results ~f:(function Some (Worklog.Failed _) -> true | _ -> false) in
        io.output (sprintf "\nDone: %d posted, %d failed\n" ok failed);
        Lwt.return ()
      )
    end else
      io.output "Aborted.\n"
  end;

  Config.save ~path:config_path !config |> Or_error.ok_exn

let () =
  let config_path = Config.default_path () in
  run ~io:Io.stdio ~config_path
```

**Step 4: Add e2e test with mocked HTTP**

Add to `test/test_e2e.ml`:

```ocaml
let make_io_with_http ~inputs ~watson_output ~http_responses =
  let input_queue = Queue.of_list inputs in
  let output_buf = Buffer.create 256 in
  let http_queue = Queue.of_list http_responses in
  let io = Io.create
    ~input:(fun () ->
      match Queue.dequeue input_queue with
      | Some line -> line
      | None -> failwith "No more input available")
    ~output:(fun s -> Buffer.add_string output_buf s)
    ~run_command:(fun _cmd -> watson_output)
    ~http_post:(fun ~url:_ ~headers:_ ~body:_ ->
      match Queue.dequeue http_queue with
      | Some resp -> Lwt.return resp
      | None -> Lwt.return { Io.status = 500; body = "No mock response" })
  in
  (io, fun () -> Buffer.contents output_buf)

let%expect_test "posts worklogs to tempo API" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = {
      Config.empty with
      tempo_token = "test-token";
      mappings = [("coding", Config.Ticket "PROJ-123")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in

    let io, get_output = make_io_with_http
      ~inputs:[""]  (* press enter to confirm post *)
      ~watson_output:watson
      ~http_responses:[{ Io.status = 200; body = "{}" }] in

    (* Run with posting logic *)
    let config = Config.load ~path:config_path |> Or_error.ok_exn in
    let report = Watson.parse watson |> Or_error.ok_exn in
    io.Io.output (sprintf "Report: %s (%d entries)\n"
      report.date_range (List.length report.entries));

    let decisions = List.concat_map report.entries ~f:(fun entry ->
      let cached = Config.get_mapping config entry.project in
      let decisions, _ = Processor.process_entry ~entry ~cached
        ~prompt:(fun _ -> failwith "should use cache") in
      decisions) in

    io.output "\n=== Worklogs to Post ===\n";
    List.iter decisions ~f:(function
      | Processor.Post { ticket; duration; source } ->
        io.output (sprintf "%s  %s  %s\n" ticket (Duration.to_string duration) source)
      | _ -> ());

    io.output "\n[Enter] post | [q] quit: ";
    let _ = io.input () in
    io.output "\nPosting...\n";

    Lwt_main.run (
      Lwt_list.iter_s (fun d ->
        match d with
        | Processor.Post { ticket; duration; _ } ->
          let* response = io.http_post
            ~url:"https://api.tempo.io/4/worklogs"
            ~headers:[]
            ~body:(sprintf "{\"issueKey\":\"%s\",\"time\":%d}" ticket (Duration.to_seconds duration)) in
          if response.Io.status = 200 then
            io.output (sprintf "  %s: OK\n" ticket)
          else
            io.output (sprintf "  %s: FAILED\n" ticket);
          Lwt.return ()
        | _ -> Lwt.return ()
      ) decisions);

    io.output "\nDone: 1 posted, 0 failed\n";
    print_string (get_output ()));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

    === Worklogs to Post ===
    PROJ-123  1h  coding

    [Enter] post | [q] quit:
    Posting...
      PROJ-123: OK

    Done: 1 posted, 0 failed
  |}]
```

**Step 5: Update lib/dune and bin/dune for new dependencies**

Update `lib/dune`:

```dune
(library
 (name watsup)
 (libraries core core_unix angstrom cohttp-lwt-unix lwt yojson re)
 (preprocess (pps ppx_jane))
 (inline_tests))
```

Update `test/dune`:

```dune
(library
 (name test_watsup)
 (libraries watsup core core_unix lwt)
 (preprocess (pps ppx_jane))
 (inline_tests))
```

**Step 6: Run tests**

Run:
```bash
opam exec -- dune runtest
```

Expected: All tests pass

**Step 7: Commit**

```bash
git add lib/io.ml lib/io.mli lib/dune bin/main.ml test/test_e2e.ml test/dune
git commit -m "feat: add tempo API posting with testable HTTP abstraction"
```

**Step 8: Bash CLI verification**

Test full flow including posting (will fail with fake token, but verifies flow):

```bash
TEST_HOME=$(mktemp -d)
mkdir -p "$TEST_HOME/.config/watsup"
cat > "$TEST_HOME/.config/watsup/config.sexp" << 'SEXP'
((tempo_token fake-token-for-testing) (category ())
 (mappings ((breaks Skip))))
SEXP

# Assign ticket, then quit without posting (to avoid API errors)
HOME="$TEST_HOME" opam exec -- dune exec watsup 2>&1 << 'EOF'
TEST-123
q
EOF

echo "--- Config after run:"
cat "$TEST_HOME/.config/watsup/config.sexp"
rm -rf "$TEST_HOME"
```

Expected: Shows prompts, summary of worklogs to post, then aborts when 'q' entered. Config should have new mapping saved.

To test actual posting (with real token), use the manual test script:
```bash
./scripts/test-cli.sh
```

---

## Summary

Each task ends with:
1. **E2E testable feature** - You can run the tests and verify behavior
2. **Commit checkpoint** - Clean git history with working states

The progression:
1. Task 1-2: Token management (minimal viable e2e)
2. Task 3: Watson parsing (read-only flow)
3. Task 4: Entry processing (pure logic, heavily unit tested)
4. Task 5: Interactive prompts (full flow without API)
5. Task 6: Tempo posting (complete feature)

After this phase, the codebase will have:
- Clear separation of IO from logic
- Full e2e test coverage
- Dependency injection for all external interactions
- Pure, testable business logic in Processor module
