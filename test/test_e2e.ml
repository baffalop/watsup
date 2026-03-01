open Core
open Watsup
module Main_logic = Watsup.Main_logic

let test_date = "2026-02-03"

let sample_watson_report =
  {|Tue 03 February 2026 -> Tue 03 February 2026

architecture - 25m 46s

breaks - 1h 20m 39s
	[coffee     20m 55s]
	[lunch     59m 44s]

cr - 51m 02s
	[DEV-101     33m 35s]
	[DEV-202     12m 37s]

Total: 2h 37m 27s|}

let empty_watson_report =
  {|Mon 03 February 2026 -> Mon 03 February 2026

Total: 0h 0m 0s|}

let with_temp_config f =
  let temp_dir = Core_unix.mkdtemp "/tmp/watsup_test" in
  let config_path = temp_dir ^/ ".config" ^/ "watsup" ^/ "config.sexp" in
  Core_unix.mkdir_p (Filename.dirname config_path);
  protect ~f:(fun () -> f ~config_path)
    ~finally:(fun () ->
      ignore @@ Core_unix.system @@ sprintf "rm -r %s" @@ Filename.quote temp_dir)

let start ~config_path ?(watson_output=[(test_date, sample_watson_report)]) f =
  let normalize s =
    String.substr_replace_all s ~pattern:config_path ~with_:"<CONFIG_PATH>"
  in
  let run_cmd cmd : string =
    List.find watson_output ~f:(fun (term, _) -> String.is_substring ~substring:term cmd)
    |> Option.value_exn ~message:("Command not found in mock command list: " ^ cmd)
    |> Tuple2.get2
  in
  Io.Mocked.run @@ fun () ->
    let open Effect.Deep in
    try f () with
    | effect Io.Output s, k ->
        print_string @@ normalize s;
        continue k ()
    | effect Io.Run_command cmd, k ->
        continue k @@ run_cmd cmd

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

let%expect_test "first-run: credentials, setup, and posting" =
  with_temp_config @@ fun ~config_path ->
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Tempo token *)
    [%expect {| Enter Tempo API token: |}];
    input t "test-tempo-token";
    (* Jira subdomain *)
    [%expect {| Enter Jira subdomain (e.g., 'company' for company.atlassian.net): |}];
    input t "mycompany";
    (* Jira email *)
    [%expect {| Enter Jira email: |}];
    input t "user@example.com";
    (* Jira API token *)
    [%expect {| Enter Jira API token (https://id.atlassian.com/manage-profile/security/api-tokens): |}];
    input t "test-jira-token";
    (* Fetches account ID via GET *)
    [%expect {| Fetching Jira account ID... |}];
    http_get t { Io.status = 200; body = {|{"accountId": "acc-id-999"}|} };
    (* Fetches work attribute keys via GET *)
    [%expect {| OK (acc-id-999) |}];
    http_get t { Io.status = 200; body = {|{"results": [
      {"name": "Account", "key": "_Account_"},
      {"name": "Category", "key": "_Category_"}
    ]}|} };
    (* Fetches category options via GET *)
    [%expect {||}];
    http_get t { Io.status = 200; body = {|{
      "names": {"dev": "Development", "met": "Meeting"},
      "values": ["dev", "met"]
    }|} };
    (* Now watson report is processed, entry prompt *)
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

      coding - 1h
        [ticket] assign | [n] skip | [S] skip always:
      |}];
    input t "PROJ-123";
    [%expect {| Description for PROJ-123 (optional): |}];
    input t "first run work";
    (* Category prompt *)
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
      >
      |}];
    input t "1";
    (* Summary + confirmation *)
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Development] from coding

      === Worklogs to Post ===
        PROJ-123: 1h - first run work
      [Enter] post | [n] skip day:
      |}];
    input t "";
    (* Posting — needs issue lookup since no cached issue_ids *)
    [%expect {|
      === Posting ===
        Looking up PROJ-123...
      |}];
    http_get t { Io.status = 200; body = {|{
      "id": "67890",
      "names": {"customfield_10201": "Account"},
      "fields": {"customfield_10201": {"id": 273, "value": "Operations"}}
    }|} };
    [%expect {||}];
    http_get t { Io.status = 200; body = {|{"key": "ACCT-1", "name": "Operations"}|} };
    [%expect {| OK (id=67890, account=ACCT-1) |}];
    http_post t { Io.status = 200; body = {|{"id": 999}|} };
    [%expect {|
      PROJ-123: OK

      Posted 1/1 worklogs
      |}];
    finish t

let%expect_test "config round-trip: mappings persist across separate runs" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson_day1 = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

breaks - 30m 00s

Total: 1h 30m 00s|} in
    let watson_day2 = {|Tue 04 February 2026 -> Tue 04 February 2026

coding - 2h 00m 00s

breaks - 45m 00s

Total: 2h 45m 00s|} in
    (* Run 1: assign coding -> PROJ-123, skip-always breaks *)
    let t1 = start ~watson_output:[("2026-02-03", watson_day1)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"])
    in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)

      coding - 1h
        [ticket] assign | [n] skip | [S] skip always:
      |}];
    input t1 "PROJ-123";
    [%expect {| Description for PROJ-123 (optional): |}];
    input t1 "day one work";
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t1 "1";
    [%expect {|
      breaks - 30m
        [ticket] assign | [n] skip | [S] skip always:
      |}];
    input t1 "S";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Development] from coding
      SKIP: breaks (30m)

      === Worklogs to Post ===
        PROJ-123: 1h - day one work
      [Enter] post | [n] skip day:
      |}];
    input t1 "n";
    [%expect {||}];
    finish t1;
    (* Run 2: same config_path, different date — mappings should auto-apply *)
    let t2 = start ~watson_output:[("2026-02-04", watson_day2)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-04"])
    in
    [%expect {|
      Report: Tue 04 February 2026 -> Tue 04 February 2026 (2 entries)
        Description for PROJ-123 (optional):
      |}];
    input t2 "";
    [%expect {|
      PROJ-123 category: Development
        [Enter] keep | [c] change:
      |}];
    input t2 "";
    [%expect {|
      === Summary ===
      POST: PROJ-123 (2h) [Development] from coding
      SKIP: breaks (45m)

      === Worklogs to Post ===
        PROJ-123: 2h
      [Enter] post | [n] skip day:
      |}];
    input t2 "n";
    [%expect {||}];
    finish t2

let%expect_test "comprehensive interactive flow" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* architecture: assign ticket *)
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
    (* breaks: skip once *)
    [%expect {|
      breaks - 1h 20m
        [coffee   20m]
        [lunch    1h]
        [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
      |}];
    input t "n";
    (* cr: split by tags *)
    [%expect {|
      cr - 50m
        [DEV-101  35m]
        [DEV-202  10m]
        [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
      |}];
    input t "s";
    (* DEV-101 tag: accept default (ticket pattern, Enter auto-accepts) *)
    [%expect {| [DEV-101  35m] [ticket] assign | [n] skip: |}];
    input t "";
    [%expect {| Description for DEV-101 (optional): |}];
    input t "review work";
    (* DEV-202 tag: accept default *)
    [%expect {| [DEV-202  10m] [ticket] assign | [n] skip: |}];
    input t "";
    [%expect {| Description for DEV-202 (optional): |}];
    input t "";
    (* Category for DEV-101 *)
    [%expect {|
      DEV-101 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    (* Category for DEV-202 *)
    [%expect {|
      DEV-202 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "2";
    (* Summary + skip *)
    [%expect {|
      === Summary ===
      POST: ARCH-1 (25m) [Development] from architecture
      POST: DEV-101 (35m) [Development] from cr:DEV-101
      POST: DEV-202 (10m) [Meeting] from cr:DEV-202

      === Worklogs to Post ===
        ARCH-1: 25m - arch work
        DEV-101: 35m - review work
        DEV-202: 10m
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "cached mappings with auto_extract and ticket" =
  with_temp_config @@ fun ~config_path ->
    let config = {
      (test_config_with_mappings [
        ("architecture", Config.Ticket "ARCH-1");
        ("breaks", Config.Skip);
        ("cr", Config.Auto_extract);
      ]) with
      tempo_token = "existing-token-xyz";
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
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
      DEV-101 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      DEV-202 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      === Summary ===
      POST: ARCH-1 (25m) [Development] from architecture
      POST: DEV-101 (35m) [Development] from cr:DEV-101
      POST: DEV-202 (10m) [Development] from cr:DEV-202
      SKIP: breaks (1h 20m)

      === Worklogs to Post ===
        ARCH-1: 25m
        DEV-101: 35m
        DEV-202: 10m
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "posting: success, failure, and issue lookup" =
  with_temp_config @@ fun ~config_path ->
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

review - 30m 00s

Total: 1h 30m 00s|} in
    let config = {
      (test_config_with_mappings [
        ("coding", Config.Ticket "PROJ-123");
        ("review", Config.Ticket "PROJ-456");
      ]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Description for PROJ-123 *)
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)
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
    (* Description for PROJ-456 *)
    [%expect {| Description for PROJ-456 (optional): |}];
    input t "";
    [%expect {|
      PROJ-456 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    (* Summary + confirm *)
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Development] from coding
      POST: PROJ-456 (30m) [Development] from review

      === Worklogs to Post ===
        PROJ-123: 1h - test work
        PROJ-456: 30m
      [Enter] post | [n] skip day:
      |}];
    input t "";
    (* Posting: PROJ-123 has cached issue_id, posts directly *)
    [%expect {| === Posting === |}];
    http_post t { Io.status = 200; body = {|{"id": 999}|} };
    (* PROJ-456 needs Jira lookup *)
    [%expect {|
      PROJ-123: OK
        Looking up PROJ-456...
      |}];
    http_get t { Io.status = 200; body = {|{
      "id": "67890",
      "names": {"customfield_10201": "Account"},
      "fields": {"customfield_10201": {"id": 273, "value": "Ops"}}
    }|} };
    [%expect {||}];
    http_get t { Io.status = 200; body = {|{"key": "ACCT-2"}|} };
    (* PROJ-456 POST fails *)
    [%expect {| OK (id=67890, account=ACCT-2) |}];
    http_post t { Io.status = 400; body = {|{"error": "Invalid issue"}|} };
    [%expect {|
      PROJ-456: FAILED (400)
        Response: {"error": "Invalid issue"}

      Posted 1/2 worklogs
      |}];
    finish t

let%expect_test "category selection and override" =
  with_temp_config @@ fun ~config_path ->
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

review - 30m 00s

Total: 1h 30m 00s|} in
    let config = {
      (test_config_with_mappings [
        ("coding", Config.Ticket "PROJ-123");
        ("review", Config.Ticket "PROJ-456");
      ]) with
      issue_ids = [("PROJ-123", 12345); ("PROJ-456", 67890)];
      account_keys = [("PROJ-123", "ACCT-1"); ("PROJ-456", "ACCT-2")];
      category_selections = [("PROJ-456", "dev")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* PROJ-123: description *)
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (2 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    (* PROJ-123: no cached category -> fresh prompt *)
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "2";
    (* PROJ-456: description *)
    [%expect {| Description for PROJ-456 (optional): |}];
    input t "";
    (* PROJ-456: cached category -> keep/change, user changes *)
    [%expect {|
      PROJ-456 category: Development
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
    (* Summary + skip *)
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Meeting] from coding
      POST: PROJ-456 (30m) [Support] from review

      === Worklogs to Post ===
        PROJ-123: 1h
        PROJ-456: 30m
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "multi-day with posting and skipping" =
  with_temp_config @@ fun ~config_path ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      issue_ids = [("PROJ-123", 12345)];
      account_keys = [("PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson_output = [
      ("2026-02-03", {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|});
      ("2026-02-04", {|Tue 04 February 2026 -> Tue 04 February 2026

coding - 2h 00m 00s

Total: 2h 00m 00s|});
    ] in
    let t = start ~watson_output ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-03"; "2026-02-04"])
    in
    (* Day 1: description *)
    [%expect {|
      === 2026-02-03 ===
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    (* Day 1: category *)
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    (* Day 1: skip day *)
    [%expect {|
      === Summary ===
      POST: PROJ-123 (1h) [Development] from coding

      === Worklogs to Post ===
        PROJ-123: 1h
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    (* Day 2: description *)
    [%expect {|
      === 2026-02-04 ===
      Report: Tue 04 February 2026 -> Tue 04 February 2026 (1 entries)
        Description for PROJ-123 (optional):
      |}];
    input t "";
    (* Day 2: category (cached from day 1) *)
    [%expect {|
      PROJ-123 category: Development
        [Enter] keep | [c] change:
      |}];
    input t "";
    (* Day 2: post *)
    [%expect {|
      === Summary ===
      POST: PROJ-123 (2h) [Development] from coding

      === Worklogs to Post ===
        PROJ-123: 2h
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

let%expect_test "split by tags: full and partial" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 1h 20m 02s
	[DEV-101     33m 35s]
	[review     12m 37s]
	[DEV-202     33m 50s]

Total: 1h 20m 02s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Entry prompt: split *)
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (1 entries)

      cr - 1h 20m
        [DEV-101  35m]
        [review   10m]
        [DEV-202  35m]
        [ticket] assign all | [s] split by tags | [n] skip | [S] skip always:
      |}];
    input t "s";
    (* DEV-101: accept default (ticket pattern, Enter) *)
    [%expect {| [DEV-101  35m] [ticket] assign | [n] skip: |}];
    input t "";
    [%expect {| Description for DEV-101 (optional): |}];
    input t "review of DEV-101";
    (* review: assign custom ticket *)
    [%expect {| [review   10m] [ticket] assign | [n] skip: |}];
    input t "REVIEW-55";
    [%expect {| Description for REVIEW-55 (optional): |}];
    input t "code review";
    (* DEV-202: skip *)
    [%expect {| [DEV-202  35m] [ticket] assign | [n] skip: |}];
    input t "n";
    (* Categories for DEV-101 and REVIEW-55 *)
    [%expect {|
      DEV-101 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      REVIEW-55 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "2";
    (* Summary + skip *)
    [%expect {|
      === Summary ===
      POST: DEV-101 (35m) [Development] from cr:DEV-101
      POST: REVIEW-55 (10m) [Meeting] from cr:review

      === Worklogs to Post ===
        DEV-101: 35m - review of DEV-101
        REVIEW-55: 10m - code review
      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "failed credential API call aborts" =
  with_temp_config @@ fun ~config_path ->
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let raised = ref false in
    (try
      let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
        Main_logic.run ~config_path ~dates:[test_date])
      in
      [%expect {| Enter Tempo API token: |}];
      input t "test-tempo-token";
      [%expect {| Enter Jira subdomain (e.g., 'company' for company.atlassian.net): |}];
      input t "mycompany";
      [%expect {| Enter Jira email: |}];
      input t "user@example.com";
      [%expect {| Enter Jira API token (https://id.atlassian.com/manage-profile/security/api-tokens): |}];
      input t "test-jira-token";
      [%expect {| Fetching Jira account ID... |}];
      http_get t { Io.status = 401; body = {|{"message": "Unauthorized"}|} };
      [%expect.unreachable];
      finish t
    with exn ->
      raised := true;
      print_endline (Exn.to_string exn));
    [%expect {|
      FAILED: Jira API error (401) at https://mycompany.atlassian.net/rest/api/2/myself: {"message": "Unauthorized"}
      (Failure "Could not fetch Jira account ID")
      |}];
    assert !raised

let%expect_test "handles empty watson report" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~watson_output:[(test_date, empty_watson_report)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {|
      Report: Mon 03 February 2026 -> Mon 03 February 2026 (0 entries)

      === Summary ===
      |}];
    finish t

