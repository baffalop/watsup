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

let make_io ?(http_get_responses=[]) ?(http_post_responses=[]) ~inputs ~watson_output () =
  let input_queue = Queue.of_list inputs in
  let output_buf = Buffer.create 256 in
  let http_get_queue = Queue.of_list http_get_responses in
  let http_post_queue = Queue.of_list http_post_responses in
  let dequeue_input () =
    match Queue.dequeue input_queue with
    | Some line -> line
    | None -> failwith "No more input available"
  in
  let io = Io.create
    ~input:dequeue_input
    ~input_secret:dequeue_input
    ~output:(fun s -> Buffer.add_string output_buf s)
    ~run_command:(fun _cmd -> watson_output)
    ~http_post:(fun ~url:_ ~headers:_ ~body:_ ->
      let resp = Queue.dequeue http_post_queue
        |> Option.value ~default:{ Io.status = 200; body = "{}" } in
      Lwt.return resp)
    ~http_get:(fun ~url:_ ~headers:_ ->
      let resp = Queue.dequeue http_get_queue
        |> Option.value ~default:{ Io.status = 200; body = "{}" } in
      Lwt.return resp)
  in
  (io, fun () -> Buffer.contents output_buf)

(* Normalize output by replacing dynamic temp paths with a placeholder *)
let normalize_output ~config_path output =
  String.substr_replace_all output ~pattern:config_path ~with_:"<CONFIG_PATH>"

(* Helper to create fully configured config for testing *)
let test_config_with_mappings mappings = {
  Config.empty with
  tempo_token = "test-tempo-token";
  jira_email = "test@example.com";
  jira_token = "test-jira-token";
  jira_base_url = "https://test.atlassian.net";
  jira_account_id = "test-account-id-123";
  tempo_account_attr_key = "_Account_";
  mappings;
}

let%expect_test "interactive flow prompts for unmapped entries" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Config has credentials but no mappings *)
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    (* Inputs: ARCH-1 for architecture, S for breaks, n for cr, description, q to quit *)
    let io, get_output = make_io
      ~inputs:["ARCH-1"; "S"; "n"; ""; "q"]
      ~watson_output:sample_watson_report () in
    Main_logic.run ~io ~config_path;
    print_string (normalize_output ~config_path (get_output ())));
  [%expect {|
    Report: Tue 03 February 2026 -> Tue 03 February 2026 (3 entries)

    architecture - 25m
      [ticket] assign | [n] skip | [S] skip always:
    breaks - 1h 20m
      [ticket] assign | [n] skip | [S] skip always:
    cr - 50m
      [ticket] assign | [n] skip | [S] skip always:
    === Summary ===
    POST: ARCH-1 (25m) from architecture
    SKIP: breaks (1h 20m)

    === Worklogs to Post ===
      ARCH-1: 25m

    Description (optional): [Enter] post | [q] quit: |}]

let%expect_test "uses cached mappings with auto_extract" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Pre-populate config with all credentials and mappings *)
    let config = {
      (test_config_with_mappings [
        ("architecture", Config.Ticket "ARCH-1");
        ("breaks", Config.Skip);
        ("cr", Config.Auto_extract);
      ]) with
      tempo_token = "existing-token-xyz";
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    (* Inputs: description, q to quit *)
    let io, get_output = make_io ~inputs:[""; "q"] ~watson_output:sample_watson_report () in
    Main_logic.run ~io ~config_path;
    print_string (normalize_output ~config_path (get_output ())));
  [%expect {|
    Report: Tue 03 February 2026 -> Tue 03 February 2026 (3 entries)

    === Summary ===
    POST: ARCH-1 (25m) from architecture
    POST: FK-3080 (35m) from cr:FK-3080
    POST: FK-3083 (10m) from cr:FK-3083
    SKIP: breaks (1h 20m)

    === Worklogs to Post ===
      ARCH-1: 25m
      FK-3080: 35m
      FK-3083: 10m

    Description (optional): [Enter] post | [q] quit: |}]

let%expect_test "handles empty watson report" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Pre-populate config with all credentials *)
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let io, get_output = make_io ~inputs:[] ~watson_output:empty_watson_report () in
    Main_logic.run ~io ~config_path;
    print_string (normalize_output ~config_path (get_output ())));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (0 entries)

    === Summary ===
    |}]

let%expect_test "interactive flow with mixed decisions" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 2h 00m 00s

breaks - 30m 00s

Total: 2h 30m 00s|} in

    (* Inputs: PROJ-123 for coding, S for breaks, description, q to quit *)
    let io, get_output = make_io
      ~inputs:["PROJ-123"; "S"; ""; "q"]
      ~watson_output:watson () in
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

    === Worklogs to Post ===
      PROJ-123: 2h

    Description (optional): [Enter] post | [q] quit: |}]

let%expect_test "skips prompts for cached mappings" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [
      ("coding", Config.Ticket "PROJ-123");
      ("breaks", Config.Skip);
    ] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 30m 00s

breaks - 45m 00s

Total: 2h 15m 00s|} in

    (* Inputs: description, q to quit - no entry prompts needed *)
    let io, get_output = make_io
      ~inputs:[""; "q"]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path;
    print_string @@ normalize_output ~config_path (get_output ()));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)

    === Summary ===
    POST: PROJ-123 (1h 30m) from coding
    SKIP: breaks (45m)

    === Worklogs to Post ===
      PROJ-123: 1h 30m

    Description (optional): [Enter] post | [q] quit: |}]

let%expect_test "posts worklogs with mocked HTTP" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Config with both issue ID and account key cached *)
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in

    (* Inputs: description "test work", Enter to confirm (not "q") *)
    let io, get_output = make_io
      ~inputs:["test work"; ""]
      ~http_post_responses:[{ Io.status = 200; body = "{\"id\": 999}" }]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path;
    print_string @@ normalize_output ~config_path (get_output ()));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

    === Summary ===
    POST: PROJ-123 (1h) from coding

    === Worklogs to Post ===
      PROJ-123: 1h

    Description (optional): [Enter] post | [q] quit:
    === Posting ===
    PROJ-123: OK

    Posted 1/1 worklogs
    |}]

let%expect_test "handles failed POST with error message" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in

    (* Mock a 400 error response *)
    let io, get_output = make_io
      ~inputs:[""; ""]
      ~http_post_responses:[{ Io.status = 400; body = "{\"error\": \"Invalid issue\"}" }]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path;
    print_string @@ normalize_output ~config_path (get_output ()));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

    === Summary ===
    POST: PROJ-123 (1h) from coding

    === Worklogs to Post ===
      PROJ-123: 1h

    Description (optional): [Enter] post | [q] quit:
    === Posting ===
    PROJ-123: FAILED (400)
      Response: {"error": "Invalid issue"}

    Posted 0/1 worklogs
    |}]

let%expect_test "looks up issue ID from Jira when not cached" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Config without cached issue ID *)
    let config = test_config_with_mappings [("coding", Config.Ticket "PROJ-123")] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in

    (* Mock Jira issue lookup returning ID + Account field, then Tempo account key lookup *)
    let jira_issue_response = {|{
      "id": "67890",
      "names": {"customfield_10201": "Account"},
      "fields": {"customfield_10201": {"id": 273, "value": "Operations"}}
    }|} in
    let tempo_account_response = {|{"key": "ACCT-2", "name": "Operations"}|} in
    let io, get_output = make_io
      ~inputs:[""; ""]
      ~http_get_responses:[
        { Io.status = 200; body = jira_issue_response };
        { Io.status = 200; body = tempo_account_response };
      ]
      ~http_post_responses:[{ Io.status = 200; body = "{}" }]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path;
    print_string @@ normalize_output ~config_path (get_output ()));
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

    === Summary ===
    POST: PROJ-123 (1h) from coding

    === Worklogs to Post ===
      PROJ-123: 1h

    Description (optional): [Enter] post | [q] quit:
    === Posting ===
      Looking up PROJ-123... OK (id=67890, account=ACCT-2)
    PROJ-123: OK

    Posted 1/1 worklogs
    |}]
