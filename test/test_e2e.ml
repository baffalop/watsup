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
    let io, get_output = make_io ~inputs:["my-secret-token-12345"] ~watson_output:sample_watson_report in
    Main_logic.run ~io ~config_path;
    print_string (normalize_output ~config_path (get_output ())));
  [%expect {|
    Enter Tempo API token: Token configured: my-secre...
    Report: Tue 03 February 2026 -> Tue 03 February 2026
    Entries: 3
      architecture - 25m
      breaks - 1h 20m
      cr - 51m
    |}]

let%expect_test "uses cached token when config exists" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Pre-populate config *)
    let config = { Config.empty with tempo_token = "existing-token-xyz" } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let io, get_output = make_io ~inputs:[] ~watson_output:sample_watson_report in
    Main_logic.run ~io ~config_path;
    print_string (normalize_output ~config_path (get_output ())));
  [%expect {|
    Token configured: existing...
    Report: Tue 03 February 2026 -> Tue 03 February 2026
    Entries: 3
      architecture - 25m
      breaks - 1h 20m
      cr - 51m
    |}]

let%expect_test "parses watson report and lists entries" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Pre-populate config with token *)
    let config = { Config.empty with tempo_token = "test-token-123" } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let io, get_output = make_io ~inputs:[] ~watson_output:sample_watson_report in
    Main_logic.run ~io ~config_path;
    print_string (normalize_output ~config_path (get_output ())));
  [%expect {|
    Token configured: test-tok...
    Report: Tue 03 February 2026 -> Tue 03 February 2026
    Entries: 3
      architecture - 25m
      breaks - 1h 20m
      cr - 51m
    |}]
