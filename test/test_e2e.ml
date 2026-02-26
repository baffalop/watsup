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

let make_io ?(http_get_responses=[]) ?(http_post_responses=[]) ?run_command ~inputs ~watson_output () =
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
  let io = Io.create
    ~input:dequeue_input
    ~input_secret:dequeue_input
    ~output:(fun s -> Buffer.add_string output_buf s)
    ~run_command:run_cmd
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

    (* Inputs: ARCH-1 for architecture, desc for ARCH-1, S for breaks, n for cr, n to skip day *)
    let io, get_output = make_io
      ~inputs:["ARCH-1"; "arch work"; "S"; "n"; "n"]
      ~watson_output:sample_watson_report () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ();
  [%expect {|
    Report: Tue 03 February 2026 -> Tue 03 February 2026 (3 entries)

    architecture - 25m
      [ticket] assign | [n] skip | [S] skip always:   Description for ARCH-1 (optional):
    breaks - 1h 20m
      [coffee   20m]
      [lunch    1h]
      [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
    cr - 50m
      [FK-3080  35m]
      [FK-3083  10m]
      [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
    === Summary ===
    POST: ARCH-1 (25m) from architecture
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

    (* Inputs: description, n to skip day *)
    let io, get_output = make_io ~inputs:[""; "n"] ~watson_output:sample_watson_report () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ();
  [%expect {|
    Report: Tue 03 February 2026 -> Tue 03 February 2026 (3 entries)
      Description for ARCH-1 (optional):
    === Summary ===
    POST: ARCH-1 (25m) from architecture
    POST: FK-3080 (35m) from cr:FK-3080
    POST: FK-3083 (10m) from cr:FK-3083
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

    let io, get_output = make_io ~inputs:[] ~watson_output:empty_watson_report () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ();
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

    (* Inputs: PROJ-123 for coding, desc, S for breaks, n to skip day *)
    let io, get_output = make_io
      ~inputs:["PROJ-123"; ""; "S"; "n"]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ());
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)

    coding - 2h
      [ticket] assign | [n] skip | [S] skip always:   Description for PROJ-123 (optional):
    breaks - 30m
      [ticket] assign | [n] skip | [S] skip always:
    === Summary ===
    POST: PROJ-123 (2h) from coding
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

    (* Inputs: description, n to skip day - no entry prompts needed *)
    let io, get_output = make_io
      ~inputs:[""; "n"]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ());
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)
      Description for PROJ-123 (optional):
    === Summary ===
    POST: PROJ-123 (1h 30m) from coding
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

    (* Inputs: description "test work", Enter to confirm (not "q") *)
    let io, get_output = make_io
      ~inputs:["test work"; ""]
      ~http_post_responses:[{ Io.status = 200; body = "{\"id\": 999}" }]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ());
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):
    === Summary ===
    POST: PROJ-123 (1h) from coding

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

    (* Mock a 400 error response. Inputs: description, Enter to confirm *)
    let io, get_output = make_io
      ~inputs:[""; ""]
      ~http_post_responses:[{ Io.status = 400; body = "{\"error\": \"Invalid issue\"}" }]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ());
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):
    === Summary ===
    POST: PROJ-123 (1h) from coding

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
    (* Inputs: description, Enter to confirm *)
    let io, get_output = make_io
      ~inputs:[""; ""]
      ~http_get_responses:[
        { Io.status = 200; body = jira_issue_response };
        { Io.status = 200; body = tempo_account_response };
      ]
      ~http_post_responses:[{ Io.status = 200; body = "{}" }]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ());
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):
    === Summary ===
    POST: PROJ-123 (1h) from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
    === Posting ===
      Looking up PROJ-123... OK (id=67890, account=ACCT-2)
    PROJ-123: OK

    Posted 1/1 worklogs
    |}]

  (*
let%expect_test "prompts for category when not cached" =
  with_temp_config (fun ~config_path ~temp_dir:_ ->
    (* Config without cached category *)
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      categories = None;
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in

    (* Mock work-attribute detail response with category values + names *)
    let category_attr_response = {|{
      "key": "_Category_",
      "name": "Activity Category",
      "type": "STATIC_LIST",
      "values": ["dev-uuid", "mtg-uuid", "sup-uuid"],
      "names": {"dev-uuid": "Development", "mtg-uuid": "Meeting", "sup-uuid": "Support"}
    }|} in
    (* Inputs: "2" to select Meeting, description, n to skip day *)
    let io, get_output = make_io
      ~inputs:["2"; ""; "n"]
      ~http_get_responses:[{ Io.status = 200; body = category_attr_response }]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ());
  [%expect {|
    Select activity category:
      1. Development
      2. Meeting
      3. Support
    > Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):
    === Summary ===
    POST: PROJ-123 (1h) from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
    |}]

let%expect_test "allows overriding cached category" =
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

    (* Inputs: "c" to change category, "3" for Support, description, n to skip day *)
    let io, get_output = make_io
      ~inputs:["c"; "3"; ""; "n"]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ());
  [%expect {|
    Category: Development
      [Enter] keep | [c] change:
    Select activity category:
      1. Development *
      2. Meeting
      3. Support
    > Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):
    === Summary ===
    POST: PROJ-123 (1h) from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
    |}]
*)

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
    (* Inputs: description+n for day1, description+n for day2 *)
    let io, get_output = make_io
      ~inputs:[""; "n"; ""; "n"]
      ~run_command
      ~watson_output:"" () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"; "2026-02-04"];
    print_string @@ normalize_output ~config_path @@ get_output ());
  [%expect {|
    === 2026-02-03 ===
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):
    === Summary ===
    POST: PROJ-123 (1h) from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
    === 2026-02-04 ===
    Report: Tue 04 February 2026 -> Tue 04 February 2026 (1 entries)
      Description for PROJ-123 (optional):
    === Summary ===
    POST: PROJ-123 (2h) from coding

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
    (* Day 1: description, n to skip. Day 2: description, Enter to post *)
    let io, get_output = make_io
      ~inputs:[""; "n"; ""; ""]
      ~run_command
      ~http_post_responses:[{ Io.status = 200; body = "{}" }]
      ~watson_output:"" () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"; "2026-02-04"];
    print_string @@ normalize_output ~config_path @@ get_output ();
  [%expect {|
    === 2026-02-03 ===
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
      Description for PROJ-123 (optional):
    === Summary ===
    POST: PROJ-123 (1h) from coding

    === Worklogs to Post ===
      PROJ-123: 1h
    [Enter] post | [n] skip day:
    === 2026-02-04 ===
    Report: Tue 04 February 2026 -> Tue 04 February 2026 (1 entries)
      Description for PROJ-123 (optional):
    === Summary ===
    POST: PROJ-123 (2h) from coding

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

    (* Inputs: "s" to split, Enter to accept FK-3080, desc, Enter to accept FK-3083, desc, n to skip day *)
    let io, get_output = make_io
      ~inputs:["s"; ""; "review work"; ""; ""; "n"]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ());
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

    cr - 50m
      [FK-3080  35m]
      [FK-3083  10m]
      [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:   [FK-3080  35m] [ticket] assign | [n] skip:   Description for FK-3080 (optional):   [FK-3083  10m] [ticket] assign | [n] skip:   Description for FK-3083 (optional):
    === Summary ===
    POST: FK-3080 (35m) from cr:FK-3080
    POST: FK-3083 (10m) from cr:FK-3083

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

    (* Inputs: "s" to split, Enter to accept FK-3080, desc, "n" to skip review, n to skip day *)
    let io, get_output = make_io
      ~inputs:["s"; ""; ""; "n"; "n"]
      ~watson_output:watson () in
    Main_logic.run ~io ~config_path ~dates:["2026-02-03"];
    print_string @@ normalize_output ~config_path @@ get_output ());
  [%expect {|
    Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

    cr - 50m
      [FK-3080  35m]
      [review   10m]
      [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:   [FK-3080  35m] [ticket] assign | [n] skip:   Description for FK-3080 (optional):   [review   10m] [ticket] assign | [n] skip:
    === Summary ===
    POST: FK-3080 (35m) from cr:FK-3080

    === Worklogs to Post ===
      FK-3080: 35m
    [Enter] post | [n] skip day:
    |}]
