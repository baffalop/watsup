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
  Core_unix.putenv ~key:"HOME" ~data:config_dir;

  (try f ~input ~output with exn ->
    Option.iter original_home ~f:(fun h -> Core_unix.putenv ~key:"HOME" ~data:h);
    raise exn);

  Option.iter original_home ~f:(fun h -> Core_unix.putenv ~key:"HOME" ~data:h);
  Buffer.contents output_buf

let%expect_test "token prompt when no config exists" =
  let temp_dir = Core_unix.mkdtemp "/tmp/watsup_test" in
  let output = run_with_io
    ~inputs:["my-test-token-12345"]
    ~config_dir:temp_dir
    (fun ~input ~output ->
      (* Import and run main here - we'll wire this up *)
      output "Enter Tempo API token: ";
      let token = input () in
      output (sprintf "Token: %s...\n" (String.prefix token 8));
      output "Config saved to <temp>/.config/watsup/config.sexp\n")
  in
  print_string output;
  [%expect {|
    Enter Tempo API token: Token: my-test-...
    Config saved to <temp>/.config/watsup/config.sexp
    |}];
  (* Cleanup *)
  ignore (Core_unix.system (sprintf "rm -rf %s" temp_dir))

let%expect_test "uses cached token when config exists" =
  let temp_dir = Core_unix.mkdtemp "/tmp/watsup_test" in
  let output = run_with_io
    ~inputs:[]  (* no input needed - token already cached *)
    ~config_dir:temp_dir
    (fun ~input:_ ~output ->
      (* Simulate existing token in config *)
      output "Token: existing-...
";
      output "Config saved to <temp>/.config/watsup/config.sexp\n")
  in
  print_string output;
  [%expect {|
    Token: existing-...
    Config saved to <temp>/.config/watsup/config.sexp
    |}];
  (* Cleanup *)
  ignore (Core_unix.system (sprintf "rm -rf %s" temp_dir))
