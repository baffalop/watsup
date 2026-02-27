open Core
open Watsup
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
      ignore @@ Core_unix.system @@ sprintf "rm -rf %s" @@ Filename.quote temp_dir)

let with_mock_io ?(http_get_responses=[]) ?(http_post_responses=[]) ?run_command ~inputs ~watson_output f =
  let input_queue = Queue.of_list inputs in
  let output_buf = Buffer.create 256 in
  let http_get_queue = Queue.of_list http_get_responses in
  let http_post_queue = Queue.of_list http_post_responses in
  let dequeue_input () =
    match Queue.dequeue input_queue with
    | Some line -> line
    | None -> failwith "No more input available"
  in
  let run_cmd = match run_command with
    | Some f -> f
    | None -> (fun _cmd -> watson_output)
  in
  let open Effect.Deep in
  try f (); Buffer.contents output_buf with
  | effect Io.Input, k -> continue k (dequeue_input () : string)
  | effect Io.Input_secret, k -> continue k (dequeue_input () : string)
  | effect (Io.Output s), k -> Buffer.add_string output_buf s; continue k ()
  | effect (Io.Run_command cmd), k -> continue k (run_cmd cmd : string)
  | effect (Io.Http_post _), k ->
      let resp : Io.http_response = Queue.dequeue http_post_queue
        |> Option.value ~default:{ Io.status = 200; body = "{}" }
      in
      continue k resp
  | effect (Io.Http_get _), k ->
      let resp : Io.http_response = Queue.dequeue http_get_queue
        |> Option.value ~default:{ Io.status = 200; body = "{}" } in
      continue k resp

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
  tempo_category_attr_key = "_Category_";
  categories = Some {
    Config.options = [
      Category.make ~value:"dev" ~name:"Development";
      Category.make ~value:"met" ~name:"Meeting";
      Category.make ~value:"sup" ~name:"Support";
    ];
    fetched_at = "2026-02-07"
  };
  mappings;
}

let%expect_test "interactive flow prompts for unmapped entries" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    (* Config has credentials but no mappings *)
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    (* Inputs: ARCH-1 for architecture, desc for ARCH-1, category 1, S for breaks, n for cr, n to skip day *)
    let output = with_mock_io
      ~inputs:["ARCH-1"; "arch work"; "1"; "S"; "n"; "n"]
      ~watson_output:sample_watson_report (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output;
  [%expect {|
    Report: Tue 03 February 2026 -> Tue 03 February 2026 (3 entries)

    architecture - 25m
      [ticket] assign | [n] skip | [S] skip always:   Description for ARCH-1 (optional):   ARCH-1 category:
        1. Development
        2. Meeting
        3. Support
      >
    breaks - 1h 20m
      [coffee   20m]
      [lunch    1h]
      [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
    cr - 50m
      [FK-3080  35m]
      [FK-3083  10m]
      [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
    === Summary ===
    POST: ARCH-1 (25m) [Development] from architecture
    SKIP: breaks (1h 20m)

    === Worklogs to Post ===
      ARCH-1: 25m - arch work
    [Enter] post | [n] skip day:
    |}]

let%expect_test "uses cached mappings with auto_extract" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
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

    (* Inputs: description, category for ARCH-1, category for FK-3080, category for FK-3083, n to skip day *)
    let output = with_mock_io ~inputs:[""; "1"; "1"; "1"; "n"] ~watson_output:sample_watson_report (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output;
  [%expect {|
    Report: Tue 03 February 2026 -> Tue 03 February 2026 (3 entries)
      Description for ARCH-1 (optional):   ARCH-1 category:
        1. Development
        2. Meeting
        3. Support
      >   FK-3080 category:
        1. Development
        2. Meeting
        3. Support
      >   FK-3083 category:
        1. Development
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: ARCH-1 (25m) [Development] from architecture
    POST: FK-3080 (35m) [Development] from cr:FK-3080
    POST: FK-3083 (10m) [Development] from cr:FK-3083
    SKIP: breaks (1h 20m)

    === Worklogs to Post ===
      ARCH-1: 25m
      FK-3080: 35m
      FK-3083: 10m
    [Enter] post | [n] skip day:
    |}]

let%expect_test "handles empty watson report" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    (* Pre-populate config with all credentials *)
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let output = with_mock_io ~inputs:[] ~watson_output:empty_watson_report (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output;
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

    (* Inputs: PROJ-123 for coding, desc, category 1, S for breaks, n to skip day *)
    let output = with_mock_io
      ~inputs:["PROJ-123"; ""; "1"; "S"; "n"]
      ~watson_output:watson (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output);
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)

    coding - 2h
      [ticket] assign | [n] skip | [S] skip always:   Description for PROJ-123 (optional):   PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
    breaks - 30m
      [ticket] assign | [n] skip | [S] skip always:
    === Summary ===
    POST: PROJ-123 (2h) [Development] from coding
    SKIP: breaks (30m)

    === Worklogs to Post ===
      PROJ-123: 2h
    [Enter] post | [n] skip day:
    |}]

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

    (* Inputs: description, category 1, n to skip day - no entry prompts needed *)
    let output = with_mock_io
      ~inputs:[""; "1"; "n"]
      ~watson_output:watson (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output);
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)
      Description for PROJ-123 (optional):   PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: PROJ-123 (1h 30m) [Development] from coding
    SKIP: breaks (45m)

    === Worklogs to Post ===
      PROJ-123: 1h 30m
    [Enter] post | [n] skip day:
    |}]

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

    (* Inputs: description "test work", category 1, Enter to confirm *)
    let output = with_mock_io
      ~inputs:["test work"; "1"; ""]
      ~http_post_responses:[{ Io.status = 200; body = "{\"id\": 999}" }]
      ~watson_output:watson (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output);
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):   PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: PROJ-123 (1h) [Development] from coding

    === Worklogs to Post ===
      PROJ-123: 1h - test work
    [Enter] post | [n] skip day:
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

    (* Mock a 400 error response. Inputs: description, category 1, Enter to confirm *)
    let output = with_mock_io
      ~inputs:[""; "1"; ""]
      ~http_post_responses:[{ Io.status = 400; body = "{\"error\": \"Invalid issue\"}" }]
      ~watson_output:watson (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output);
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):   PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: PROJ-123 (1h) [Development] from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
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
    (* Inputs: description, category 1, Enter to confirm *)
    let output = with_mock_io
      ~inputs:[""; "1"; ""]
      ~http_get_responses:[
        { Io.status = 200; body = jira_issue_response };
        { Io.status = 200; body = tempo_account_response };
      ]
      ~http_post_responses:[{ Io.status = 200; body = "{}" }]
      ~watson_output:watson (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output);
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):   PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: PROJ-123 (1h) [Development] from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
    === Posting ===
      Looking up PROJ-123... OK (id=67890, account=ACCT-2)
    PROJ-123: OK

    Posted 1/1 worklogs
    |}]

let%expect_test "prompts for category per worklog when not cached" =
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

    (* Inputs: description, "2" to select Meeting category, Enter to confirm post *)
    let output = with_mock_io
      ~inputs:[""; "2"; ""]
      ~http_post_responses:[{ Io.status = 200; body = "{}" }]
      ~watson_output:watson (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output);
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):   PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: PROJ-123 (1h) [Meeting] from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
    === Posting ===
    PROJ-123: OK

    Posted 1/1 worklogs
    |}]

let%expect_test "allows overriding cached category per worklog" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
      category_selections = [("PROJ-123", "dev")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in

    (* Inputs: description, "c" to change category, "3" for Support, n to skip day *)
    let output = with_mock_io
      ~inputs:[""; "c"; "3"; "n"]
      ~watson_output:watson (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output);
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):   PROJ-123 category: Development
        [Enter] keep | [c] change:     1. Development *
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: PROJ-123 (1h) [Support] from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
    |}]

let%expect_test "multi-day processing with day headers" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [
      ("coding", Config.Ticket "PROJ-123");
    ] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson_day1 = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let watson_day2 = {|Tue 04 February 2026 -> Tue 04 February 2026

coding - 2h 00m 00s

Total: 2h 00m 00s|} in

    let run_command cmd =
      if String.is_substring cmd ~substring:"2026-02-03" then watson_day1
      else if String.is_substring cmd ~substring:"2026-02-04" then watson_day2
      else failwith @@ sprintf "Unexpected command: %s" cmd
    in
    (* Inputs: description+category+n for day1, description+keep category+n for day2 *)
    let output = with_mock_io
      ~inputs:[""; "1"; "n"; ""; ""; "n"]
      ~run_command
      ~watson_output:"" (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"; "2026-02-04"]) in
    print_string @@ normalize_output ~config_path output);
  [%expect {|
    === 2026-02-03 ===
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):   PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: PROJ-123 (1h) [Development] from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
    === 2026-02-04 ===
    Report: Tue 04 February 2026 -> Tue 04 February 2026 (1 entries)
      Description for PROJ-123 (optional):   PROJ-123 category: Development
        [Enter] keep | [c] change:
    === Summary ===
    POST: PROJ-123 (2h) [Development] from coding

    === Worklogs to Post ===
      PROJ-123: 2h
    [Enter] post | [n] skip day:
    |}]

let%expect_test "skip day continues to next day" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson_day1 = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let watson_day2 = {|Tue 04 February 2026 -> Tue 04 February 2026

coding - 2h 00m 00s

Total: 2h 00m 00s|} in

    let run_command cmd =
      if String.is_substring cmd ~substring:"2026-02-03" then watson_day1
      else if String.is_substring cmd ~substring:"2026-02-04" then watson_day2
      else failwith @@ sprintf "Unexpected command: %s" cmd
    in
    (* Day 1: description, category, n to skip. Day 2: description, keep category, Enter to post *)
    let output = with_mock_io
      ~inputs:[""; "1"; "n"; ""; ""; ""]
      ~run_command
      ~http_post_responses:[{ Io.status = 200; body = "{}" }]
      ~watson_output:"" (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"; "2026-02-04"]) in
    print_string @@ normalize_output ~config_path output;
  [%expect {|
    === 2026-02-03 ===
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):   PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: PROJ-123 (1h) [Development] from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
    === 2026-02-04 ===
    Report: Tue 04 February 2026 -> Tue 04 February 2026 (1 entries)
      Description for PROJ-123 (optional):   PROJ-123 category: Development
        [Enter] keep | [c] change:
    === Summary ===
    POST: PROJ-123 (2h) [Development] from coding

    === Worklogs to Post ===
      PROJ-123: 2h
    [Enter] post | [n] skip day:
    === Posting ===
    PROJ-123: OK

    Posted 1/1 worklogs
    |}]

let%expect_test "split by tags creates per-tag decisions" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 51m 02s
	[FK-3080     33m 35s]
	[FK-3083     12m 37s]

Total: 51m 02s|} in

    (* Inputs: "s" to split, Enter to accept FK-3080, desc, Enter to accept FK-3083, desc, category for FK-3080, category for FK-3083, n to skip day *)
    let output = with_mock_io
      ~inputs:["s"; ""; "review work"; ""; ""; "1"; "1"; "n"]
      ~watson_output:watson (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output);
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

    cr - 50m
      [FK-3080  35m]
      [FK-3083  10m]
      [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:   [FK-3080  35m] [ticket] assign | [n] skip:   Description for FK-3080 (optional):   [FK-3083  10m] [ticket] assign | [n] skip:   Description for FK-3083 (optional):   FK-3080 category:
        1. Development
        2. Meeting
        3. Support
      >   FK-3083 category:
        1. Development
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: FK-3080 (35m) [Development] from cr:FK-3080
    POST: FK-3083 (10m) [Development] from cr:FK-3083

    === Worklogs to Post ===
      FK-3080: 35m - review work
      FK-3083: 10m
    [Enter] post | [n] skip day:
    |}]

let%expect_test "split with tag skip" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 51m 02s
	[FK-3080     33m 35s]
	[review     12m 37s]

Total: 51m 02s|} in

    (* Inputs: "s" to split, Enter to accept FK-3080, desc, "n" to skip review, category for FK-3080, n to skip day *)
    let output = with_mock_io
      ~inputs:["s"; ""; ""; "n"; "1"; "n"]
      ~watson_output:watson (fun () ->
        Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    print_string @@ normalize_output ~config_path output);
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

    cr - 50m
      [FK-3080  35m]
      [review   10m]
      [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:   [FK-3080  35m] [ticket] assign | [n] skip:   Description for FK-3080 (optional):   [review   10m] [ticket] assign | [n] skip:   FK-3080 category:
        1. Development
        2. Meeting
        3. Support
      >
    === Summary ===
    POST: FK-3080 (35m) [Development] from cr:FK-3080

    === Worklogs to Post ===
      FK-3080: 35m
    [Enter] post | [n] skip day:
    |}]
