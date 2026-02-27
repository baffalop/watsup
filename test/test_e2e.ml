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

let start ?run_command ~watson_output ~config_path f =
  let normalize s =
    String.substr_replace_all s ~pattern:config_path ~with_:"<CONFIG_PATH>"
  in
  let run_cmd : string -> string = match run_command with
    | Some fn -> fn
    | None -> (fun _cmd -> watson_output)
  in
  Io.Mocked.run @@ fun () ->
    let open Effect.Deep in
    try f () with
    | effect Io.Output s, k ->
        print_string @@ normalize s;
        continue k ()
    | effect Io.Run_command cmd, k -> continue k @@ run_cmd cmd

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

open Io.Mocked

let%expect_test "interactive flow prompts for unmapped entries" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~watson_output:sample_watson_report ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Tue 03 February 2026 -> Tue 03 February 2026 (3 entries)

      architecture - 25m
        [ticket] assign | [n] skip | [S] skip always:
      |}];
    input t "ARCH-1";
    [%expect {| Description for ARCH-1 (optional): |}];
    input t "arch work";
    [%expect {|
      ARCH-1 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      breaks - 1h 20m
        [coffee   20m]
        [lunch    1h]
        [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
      |}];
    input t "S";
    [%expect {|
      cr - 50m
        [FK-3080  35m]
        [FK-3083  10m]
        [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
      |}];
    input t "n";
    [%expect {|
      === Summary ===
      POST: ARCH-1 (25m) [Development] from architecture
      SKIP: breaks (1h 20m)

      === Worklogs to Post ===
        ARCH-1: 25m - arch work
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {| |}];
    finish t

let%expect_test "uses cached mappings with auto_extract" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = {
      (test_config_with_mappings [
        ("architecture", Config.Ticket "ARCH-1");
        ("breaks", Config.Skip);
        ("cr", Config.Auto_extract);
      ]) with
      tempo_token = "existing-token-xyz";
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~watson_output:sample_watson_report ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Tue 03 February 2026 -> Tue 03 February 2026 (3 entries)
        Description for ARCH-1 (optional):
      |}];
    input t "";
    [%expect {|
      ARCH-1 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      FK-3080 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      FK-3083 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
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
      |}];
    input t "n";
    [%expect {| |}];
    finish t

let%expect_test "handles empty watson report" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~watson_output:empty_watson_report ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (0 entries)

      === Summary ===
      |}];
    finish t

let%expect_test "interactive flow with mixed decisions" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 2h 00m 00s

breaks - 30m 00s

Total: 2h 30m 00s|} in
    let t = start ~watson_output:watson ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)

      coding - 2h
        [ticket] assign | [n] skip | [S] skip always:
      |}];
    input t "PROJ-123";
    [%expect {| Description for PROJ-123 (optional): |}];
    input t "";
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      breaks - 30m
        [ticket] assign | [n] skip | [S] skip always:
      |}];
    input t "S";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (2h) [Development] from coding
      SKIP: breaks (30m)

      === Worklogs to Post ===
        PROJ-123: 2h
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {| |}];
    finish t

let%expect_test "skips prompts for cached mappings" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [
      ("coding", Config.Ticket "PROJ-123");
      ("breaks", Config.Skip);
    ] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 30m 00s

breaks - 45m 00s

Total: 2h 15m 00s|} in
    let t = start ~watson_output:watson ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h 30m) [Development] from coding
      SKIP: breaks (45m)

      === Worklogs to Post ===
        PROJ-123: 1h 30m
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {| |}];
    finish t

let%expect_test "posts worklogs with mocked HTTP" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:watson ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "test work";
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Development] from coding

      === Worklogs to Post ===
        PROJ-123: 1h - test work
      [Enter] post | [n] skip day:
      |}];
    input t "";
    [%expect {| === Posting === |}];
    http_post t { Io.status = 200; body = {|{"id": 999}|} };
    [%expect {|
      PROJ-123: OK

      Posted 1/1 worklogs
      |}];
    finish t

let%expect_test "handles failed POST with error message" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:watson ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Development] from coding

      === Worklogs to Post ===
        PROJ-123: 1h
      [Enter] post | [n] skip day:
      |}];
    input t "";
    [%expect {| === Posting === |}];
    http_post t { Io.status = 400; body = {|{"error": "Invalid issue"}|} };
    [%expect {|
      PROJ-123: FAILED (400)
        Response: {"error": "Invalid issue"}

      Posted 0/1 worklogs
      |}];
    finish t

let%expect_test "looks up issue ID from Jira when not cached" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [("coding", Config.Ticket "PROJ-123")] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let jira_issue_response = {|{
      "id": "67890",
      "names": {"customfield_10201": "Account"},
      "fields": {"customfield_10201": {"id": 273, "value": "Operations"}}
    }|} in
    let tempo_account_response = {|{"key": "ACCT-2", "name": "Operations"}|} in
    let t = start ~watson_output:watson ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Development] from coding

      === Worklogs to Post ===
        PROJ-123: 1h
      [Enter] post | [n] skip day:
      |}];
    input t "";
    [%expect {|
      === Posting ===
        Looking up PROJ-123...
      |}];
    http_get t { Io.status = 200; body = jira_issue_response };
    [%expect {| |}];
    http_get t { Io.status = 200; body = tempo_account_response };
    [%expect {| OK (id=67890, account=ACCT-2) |}];
    http_post t { Io.status = 200; body = "{}" };
    [%expect {|
      PROJ-123: OK

      Posted 1/1 worklogs
      |}];
    finish t

let%expect_test "prompts for category per worklog when not cached" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:watson ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "2";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Meeting] from coding

      === Worklogs to Post ===
        PROJ-123: 1h
      [Enter] post | [n] skip day:
      |}];
    input t "";
    [%expect {| === Posting === |}];
    http_post t { Io.status = 200; body = "{}" };
    [%expect {|
      PROJ-123: OK

      Posted 1/1 worklogs
      |}];
    finish t

let%expect_test "allows overriding cached category per worklog" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
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
    let t = start ~watson_output:watson ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    [%expect {|
      PROJ-123 category: Development
        [Enter] keep | [c] change:
      |}];
    input t "c";
    [%expect {|
        1. Development *
        2. Meeting
        3. Support
      >
      |}];
    input t "3";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Support] from coding

      === Worklogs to Post ===
        PROJ-123: 1h
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {| |}];
    finish t

let%expect_test "multi-day processing with day headers" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
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
    let t = start ~run_command ~watson_output:"" ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"; "2026-02-04"]) in
    [%expect {|
      === 2026-02-03 ===
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Development] from coding

      === Worklogs to Post ===
        PROJ-123: 1h
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {|
      === 2026-02-04 ===
      Report: Tue 04 February 2026 -> Tue 04 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    [%expect {|
      PROJ-123 category: Development
        [Enter] keep | [c] change:
      |}];
    input t "";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (2h) [Development] from coding

      === Worklogs to Post ===
        PROJ-123: 2h
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {| |}];
    finish t

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
    let t = start ~run_command ~watson_output:"" ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"; "2026-02-04"]) in
    [%expect {|
      === 2026-02-03 ===
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Development] from coding

      === Worklogs to Post ===
        PROJ-123: 1h
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {|
      === 2026-02-04 ===
      Report: Tue 04 February 2026 -> Tue 04 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    [%expect {|
      PROJ-123 category: Development
        [Enter] keep | [c] change:
      |}];
    input t "";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (2h) [Development] from coding

      === Worklogs to Post ===
        PROJ-123: 2h
      [Enter] post | [n] skip day:
      |}];
    input t "";
    [%expect {| === Posting === |}];
    http_post t { Io.status = 200; body = "{}" };
    [%expect {|
      PROJ-123: OK

      Posted 1/1 worklogs
      |}];
    finish t

let%expect_test "split by tags creates per-tag decisions" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 51m 02s
	[FK-3080     33m 35s]
	[FK-3083     12m 37s]

Total: 51m 02s|} in
    let t = start ~watson_output:watson ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

      cr - 50m
        [FK-3080  35m]
        [FK-3083  10m]
        [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
      |}];
    input t "s";
    [%expect {| [FK-3080  35m] [ticket] assign | [n] skip: |}];
    input t "";
    [%expect {| Description for FK-3080 (optional): |}];
    input t "review work";
    [%expect {| [FK-3083  10m] [ticket] assign | [n] skip: |}];
    input t "";
    [%expect {| Description for FK-3083 (optional): |}];
    input t "";
    [%expect {|
      FK-3080 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      FK-3083 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      === Summary ===
      POST: FK-3080 (35m) [Development] from cr:FK-3080
      POST: FK-3083 (10m) [Development] from cr:FK-3083

      === Worklogs to Post ===
        FK-3080: 35m - review work
        FK-3083: 10m
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {| |}];
    finish t

let%expect_test "split with tag skip" =
  with_temp_config @@ fun ~config_path ~temp_dir:_ ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 51m 02s
	[FK-3080     33m 35s]
	[review     12m 37s]

Total: 51m 02s|} in
    let t = start ~watson_output:watson ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"]) in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

      cr - 50m
        [FK-3080  35m]
        [review   10m]
        [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
      |}];
    input t "s";
    [%expect {| [FK-3080  35m] [ticket] assign | [n] skip: |}];
    input t "";
    [%expect {| Description for FK-3080 (optional): |}];
    input t "";
    [%expect {| [review   10m] [ticket] assign | [n] skip: |}];
    input t "n";
    [%expect {|
      FK-3080 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      === Summary ===
      POST: FK-3080 (35m) [Development] from cr:FK-3080

      === Worklogs to Post ===
        FK-3080: 35m
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {| |}];
    finish t
