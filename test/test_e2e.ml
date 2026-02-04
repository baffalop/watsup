open Core
module Config = Watsup.Config
module Io = Watsup.Io
module Main_logic = Watsup.Main_logic

let sample_watson_report =
  {|Tue 03 February 2026 -> Tue 03 February 2026

architecture - 25m 46s

breaks - 1h 20m 39s
	[coffee     20m 55s]
	[lunch     59m 44s]

cr - 51m 02s
	[FK-3080     33m 35s]
	[FK-3083     12m 37s]

Total: 2h 37m 27s|}

let empty_watson_report =
  {|Mon 03 February 2026 -> Mon 03 February 2026

Total: 0h 0m 0s|}

let with_temp_config f =
  let temp_dir = Core_unix.mkdtemp "/tmp/watsup_test" in
  let config_path = temp_dir ^/ ".config" ^/ "watsup" ^/ "config.sexp" in
  Core_unix.mkdir_p (Filename.dirname config_path);
  protect ~f:(fun () -> f ~config_path ~temp_dir)
    ~finally:(fun () ->
      ignore (Core_unix.system (sprintf "rm -rf %s" (Filename.quote temp_dir))))

let make_io ~inputs ~watson_output =
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

(* Normalize output by replacing dynamic temp paths with a placeholder *)
let normalize_output ~config_path output =
  String.substr_replace_all output ~pattern:config_path ~with_:"<CONFIG_PATH>"

let%expect_test "prompts for token when no config exists" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Need inputs: token, then prompts for 3 entries (architecture, breaks, cr) *)
    let io, get_output = make_io
      ~inputs:["my-secret-token-12345"; "ARCH-1"; "S"; "n"]
      ~watson_output:sample_watson_report in
    Main_logic.run ~io ~config_path;
    print_string (normalize_output ~config_path (get_output ())));
  [%expect {|
    Enter Tempo API token: Report: Tue 03 February 2026 -> Tue 03 February 2026 (3 entries)

    architecture - 25m
      [ticket] assign | [n] skip | [S] skip always:
    breaks - 1h 20m
      [ticket] assign | [n] skip | [S] skip always:
    cr - 50m
      [ticket] assign | [n] skip | [S] skip always:
    === Summary ===
    POST: ARCH-1 (25m) from architecture
    SKIP: breaks (1h 20m)
    |}]

let%expect_test "uses cached token when config exists" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Pre-populate config with token and mappings for all entries *)
    let config = {
      Config.empty with
      tempo_token = "existing-token-xyz";
      mappings = [
        ("architecture", Config.Ticket "ARCH-1");
        ("breaks", Config.Skip);
        ("cr", Config.Auto_extract);
      ];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let io, get_output = make_io ~inputs:[] ~watson_output:sample_watson_report in
    Main_logic.run ~io ~config_path;
    print_string (normalize_output ~config_path (get_output ())));
  [%expect {|
    Report: Tue 03 February 2026 -> Tue 03 February 2026 (3 entries)

    === Summary ===
    POST: ARCH-1 (25m) from architecture
    POST: FK-3080 (35m) from cr:FK-3080
    POST: FK-3083 (10m) from cr:FK-3083
    SKIP: breaks (1h 20m)
    |}]

let%expect_test "parses watson report and lists entries" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Pre-populate config with token *)
    let config = { Config.empty with tempo_token = "test-token-123" } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let io, get_output = make_io ~inputs:[] ~watson_output:empty_watson_report in
    Main_logic.run ~io ~config_path;
    print_string (normalize_output ~config_path (get_output ())));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (0 entries)

    === Summary ===
    |}]

let%expect_test "interactive flow with mixed inputs" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = { Config.empty with tempo_token = "test-token" } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 2h 00m 00s

breaks - 30m 00s

Total: 2h 30m 00s|} in

    let io, get_output = make_io
      ~inputs:["PROJ-123"; "S"]  (* assign ticket to coding, skip-always breaks *)
      ~watson_output:watson in
    Main_logic.run ~io ~config_path;
    print_string @@ normalize_output ~config_path (get_output ()));
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

    let io, get_output = make_io
      ~inputs:[]  (* no prompts needed - all cached *)
      ~watson_output:watson in
    Main_logic.run ~io ~config_path;
    print_string @@ normalize_output ~config_path (get_output ()));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)

    === Summary ===
    POST: PROJ-123 (1h 30m) from coding
    SKIP: breaks (45m)
    |}]
