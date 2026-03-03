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
  starred_projects = Some ["DEV"];
  mappings;
}

(* Helper: mock a successful Jira issue lookup for lookup_cached_ticket or prompt_loop lookup *)
let jira_issue_response ~key ~summary ~id =
  { Io.status = 200;
    body = sprintf {|{"id": "%d", "key": "%s", "fields": {"summary": "%s"}}|} id key summary }

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
    (* Account ID fetched, starred projects prompt *)
    [%expect {|
      OK (acc-id-999)
      No starred projects configured.
      Enter comma-separated Jira project keys to prioritise in search (e.g. DEV,ARCH):
      |}];
    input t "PROJ,ARCH";
    [%expect {| Starred projects: PROJ, ARCH |}];
    (* Fetches work attribute keys via GET *)
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
    (* Now watson report is processed, entry prompt with Jira search *)
    [%expect {|
      coding - 1h
        [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always:
      |}];
    (* User types a ticket key directly *)
    input t "PROJ-123";
    (* Jira lookup for the ticket *)
    [%expect {| Looking up PROJ-123... |}];
    http_get t (jira_issue_response ~key:"PROJ-123" ~summary:"First run task" ~id:67890);
    (* Lookup succeeded, confirm *)
    [%expect {|
        PROJ-123  First run task
        [Enter] confirm | [text] search again | [n] back:
      |}];
    input t "";
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
      Post:
        PROJ-123   (1h)  [Development]  coding  "first run work"

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
      coding - 1h
        [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always:
      |}];
    (* User types ticket key *)
    input t1 "PROJ-123";
    [%expect {| Looking up PROJ-123... |}];
    http_get t1 (jira_issue_response ~key:"PROJ-123" ~summary:"Project task" ~id:12345);
    [%expect {|
        PROJ-123  Project task
        [Enter] confirm | [text] search again | [n] back:
      |}];
    input t1 "";
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
        [Enter] search "breaks" | [ticket/search] | [n] skip | [S] skip always:
      |}];
    input t1 "S";
    [%expect {|
      === Summary ===
      Post:
        PROJ-123   (1h)  [Development]  coding  "day one work"
      Skip:
        breaks     (30m)

      [Enter] post | [n] skip day:
      |}];
    input t1 "n";
    [%expect {||}];
    finish t1;
    (* Run 2: same config_path, different date — mappings should auto-apply *)
    let t2 = start ~watson_output:[("2026-02-04", watson_day2)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:["2026-02-04"])
    in
    (* coding: cached ticket prompt — now does lookup first *)
    [%expect {| coding - 2h  Looking up PROJ-123... |}];
    http_get t2 (jira_issue_response ~key:"PROJ-123" ~summary:"Project task" ~id:12345);
    [%expect {|
      OK
        [-> PROJ-123 "Project task"]
        [Enter] keep | [t] ticket | [c] category | [n] skip:
      |}];
    input t2 "";
    [%expect {| Description for PROJ-123 (optional): |}];
    input t2 "";
    (* Category: cached from run 1 *)
    [%expect {|
      PROJ-123 category: Development
        [Enter] keep | [c] change:
      |}];
    input t2 "";
    (* breaks: cached skip prompt *)
    [%expect {|
      breaks - 45m  [skip]
        [Enter] keep | [t] assign ticket:
      |}];
    input t2 "";
    [%expect {|
      === Summary ===
      Post:
        PROJ-123   (2h)  [Development]  coding
      Skip:
        breaks     (45m)

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
    (* architecture: assign ticket via search prompt *)
    [%expect {|
      architecture - 25m
        [Enter] search "architecture" | [ticket/search] | [n] skip | [S] skip always:
      |}];
    input t "ARCH-1";
    [%expect {| Looking up ARCH-1... |}];
    http_get t (jira_issue_response ~key:"ARCH-1" ~summary:"Architecture task" ~id:100);
    [%expect {|
        ARCH-1  Architecture task
        [Enter] confirm | [text] search again | [n] back:
      |}];
    input t "";
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

        [Enter] search "breaks coffee lunch" | [ticket/search] | [s] split | [n] skip | [S] skip always:
      |}];
    input t "n";
    (* cr: split by tags *)
    [%expect {|
      cr - 50m
        [DEV-101  35m]
        [DEV-202  10m]

        [Enter] search "cr DEV-101 DEV-202" | [ticket/search] | [s] split | [n] skip | [S] skip always:
      |}];
    input t "s";
    (* DEV-101 tag: auto-detected ticket pattern, lookup via lookup_cached_ticket *)
    [%expect {| [DEV-101  35m]   Looking up DEV-101... |}];
    http_get t (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
      [-> DEV-101 "Dev task 101"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t "";
    [%expect {| Description for DEV-101 (optional): |}];
    input t "review work";
    (* DEV-202 tag: auto-detected ticket pattern, lookup *)
    [%expect {| [DEV-202  10m]   Looking up DEV-202... |}];
    http_get t (jira_issue_response ~key:"DEV-202" ~summary:"Dev task 202" ~id:202);
    [%expect {|
      OK
      [-> DEV-202 "Dev task 202"] [Enter] keep | [t] change | [n] skip:
      |}];
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
      Post:
        ARCH-1     (25m)  [Development]  architecture  "arch work"
        DEV-101    (35m)  [Development]  cr:DEV-101  "review work"
        DEV-202    (10m)  [Meeting]  cr:DEV-202

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "cached mappings: ticket and skip (cr uncached)" =
  with_temp_config @@ fun ~config_path ->
    let config = {
      (test_config_with_mappings [
        ("architecture", Config.Ticket "ARCH-1");
        ("breaks", Config.Skip);
      ]) with
      tempo_token = "existing-token-xyz";
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* architecture: cached ticket prompt — lookup first *)
    [%expect {| architecture - 25m  Looking up ARCH-1... |}];
    http_get t (jira_issue_response ~key:"ARCH-1" ~summary:"Architecture task" ~id:100);
    [%expect {|
      OK
        [-> ARCH-1 "Architecture task"]
        [Enter] keep | [t] ticket | [c] category | [n] skip:
      |}];
    input t "";
    [%expect {| Description for ARCH-1 (optional): |}];
    input t "";
    [%expect {|
      ARCH-1 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    (* breaks: cached skip prompt *)
    [%expect {|
      breaks - 1h 20m
        [coffee   20m]
        [lunch    1h]
        [skip]
        [Enter] keep | [t] assign ticket:
      |}];
    input t "";
    (* cr is uncached, so it prompts with search *)
    [%expect {|
      cr - 50m
        [DEV-101  35m]
        [DEV-202  10m]

        [Enter] search "cr DEV-101 DEV-202" | [ticket/search] | [s] split | [n] skip | [S] skip always:
      |}];
    input t "s";
    (* DEV-101 tag: auto-detected ticket pattern, lookup *)
    [%expect {| [DEV-101  35m]   Looking up DEV-101... |}];
    http_get t (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
      [-> DEV-101 "Dev task 101"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t "";
    [%expect {| Description for DEV-101 (optional): |}];
    input t "";
    (* DEV-202 tag: auto-detected ticket pattern, lookup *)
    [%expect {| [DEV-202  10m]   Looking up DEV-202... |}];
    http_get t (jira_issue_response ~key:"DEV-202" ~summary:"Dev task 202" ~id:202);
    [%expect {|
      OK
      [-> DEV-202 "Dev task 202"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t "";
    [%expect {| Description for DEV-202 (optional): |}];
    input t "";
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
      Post:
        ARCH-1     (25m)  [Development]  architecture
        DEV-101    (35m)  [Development]  cr:DEV-101
        DEV-202    (10m)  [Development]  cr:DEV-202
      Skip:
        breaks     (1h 20m)

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
    (* coding: cached ticket prompt — lookup first *)
    [%expect {| coding - 1h  Looking up PROJ-123... |}];
    http_get t (jira_issue_response ~key:"PROJ-123" ~summary:"Project task" ~id:12345);
    [%expect {|
      OK
        [-> PROJ-123 "Project task"]
        [Enter] keep | [t] ticket | [c] category | [n] skip:
      |}];
    input t "";
    (* Description for PROJ-123 *)
    [%expect {| Description for PROJ-123 (optional): |}];
    input t "test work";
    [%expect {|
      PROJ-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    (* review: cached ticket prompt — lookup first *)
    [%expect {|
      review - 30m  Looking up PROJ-456...
      |}];
    http_get t (jira_issue_response ~key:"PROJ-456" ~summary:"Review task" ~id:67890);
    [%expect {|
      OK
        [-> PROJ-456 "Review task"]
        [Enter] keep | [t] ticket | [c] category | [n] skip:
      |}];
    input t "";
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
      Post:
        PROJ-123   (1h)  [Development]  coding  "test work"
        PROJ-456   (30m)  [Development]  review

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
    (* coding: cached ticket prompt — lookup first *)
    [%expect {| coding - 1h  Looking up PROJ-123... |}];
    http_get t (jira_issue_response ~key:"PROJ-123" ~summary:"Project task" ~id:12345);
    [%expect {|
      OK
        [-> PROJ-123 "Project task"]
        [Enter] keep | [t] ticket | [c] category | [n] skip:
      |}];
    input t "";
    (* PROJ-123: description *)
    [%expect {| Description for PROJ-123 (optional): |}];
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
    (* review: cached ticket prompt — lookup first *)
    [%expect {|
      review - 30m  Looking up PROJ-456...
      |}];
    http_get t (jira_issue_response ~key:"PROJ-456" ~summary:"Review task" ~id:67890);
    [%expect {|
      OK
        [-> PROJ-456 "Review task"]
        [Enter] keep | [t] ticket | [c] category | [n] skip:
      |}];
    input t "";
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
      Post:
        PROJ-123   (1h)  [Meeting]  coding
        PROJ-456   (30m)  [Support]  review

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
    (* Day 1: cached ticket prompt — lookup first *)
    [%expect {|
      === 2026-02-03 ===

      coding - 1h  Looking up PROJ-123...
      |}];
    http_get t (jira_issue_response ~key:"PROJ-123" ~summary:"Project task" ~id:12345);
    [%expect {|
      OK
        [-> PROJ-123 "Project task"]
        [Enter] keep | [t] ticket | [c] category | [n] skip:
      |}];
    input t "";
    (* Day 1: description *)
    [%expect {| Description for PROJ-123 (optional): |}];
    input t "";
    (* Day 1: category (no cached category yet) *)
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
      Post:
        PROJ-123   (1h)  [Development]  coding

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    (* Day 2: cached ticket prompt — lookup first *)
    [%expect {|
      === 2026-02-04 ===

      coding - 2h  Looking up PROJ-123...
      |}];
    http_get t (jira_issue_response ~key:"PROJ-123" ~summary:"Project task" ~id:12345);
    [%expect {|
      OK
        [-> PROJ-123 "Project task"]
        [Enter] keep | [t] ticket | [c] category | [n] skip:
      |}];
    input t "";
    (* Day 2: description *)
    [%expect {| Description for PROJ-123 (optional): |}];
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
      Post:
        PROJ-123   (2h)  [Development]  coding

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
      cr - 1h 20m
        [DEV-101  35m]
        [review   10m]
        [DEV-202  35m]

        [Enter] search "cr DEV-101 review DEV-202" | [ticket/search] | [s] split | [n] skip | [S] skip always:
      |}];
    input t "s";
    (* DEV-101: auto-detected ticket pattern, lookup via cached_ticket *)
    [%expect {| [DEV-101  35m]   Looking up DEV-101... |}];
    http_get t (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
      [-> DEV-101 "Dev task 101"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t "";
    [%expect {| Description for DEV-101 (optional): |}];
    input t "review of DEV-101";
    (* review: uncached non-ticket tag, search prompt *)
    [%expect {| [review   10m]   [Enter] search "cr review" | [ticket/search] | [n] skip | [S] skip always: |}];
    input t "REVIEW-55";
    [%expect {| Looking up REVIEW-55... |}];
    http_get t (jira_issue_response ~key:"REVIEW-55" ~summary:"Code review task" ~id:55);
    [%expect {|
        REVIEW-55  Code review task
        [Enter] confirm | [text] search again | [n] back:
      |}];
    input t "";
    [%expect {| Description for REVIEW-55 (optional): |}];
    input t "code review";
    (* DEV-202: auto-detected ticket pattern, lookup *)
    [%expect {| [DEV-202  35m]   Looking up DEV-202... |}];
    http_get t (jira_issue_response ~key:"DEV-202" ~summary:"Dev task 202" ~id:202);
    [%expect {|
      OK
      [-> DEV-202 "Dev task 202"] [Enter] keep | [t] change | [n] skip:
      |}];
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
      Post:
        DEV-101    (35m)  [Development]  cr:DEV-101  "review of DEV-101"
        REVIEW-55  (10m)  [Meeting]  cr:review  "code review"

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
    [%expect {| === Summary === |}];
    finish t

let%expect_test "cached ticket: keep all" =
  with_temp_config @@ fun ~config_path ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket "PROJ-123")]) with
      category_selections = [("PROJ-123", "dev")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Context + cached prompt: lookup first *)
    [%expect {| coding - 1h  Looking up PROJ-123... |}];
    http_get t (jira_issue_response ~key:"PROJ-123" ~summary:"Project task" ~id:12345);
    [%expect {|
      OK
        [-> PROJ-123 "Project task"]
        [Enter] keep | [t] ticket | [c] category | [n] skip:
      |}];
    input t "";
    (* Description prompt *)
    [%expect {| Description for PROJ-123 (optional): |}];
    input t "daily work";
    (* Category: cached, keep *)
    [%expect {|
      PROJ-123 category: Development
        [Enter] keep | [c] change:
      |}];
    input t "";
    (* Summary + skip *)
    [%expect {|
      === Summary ===
      Post:
        PROJ-123   (1h)  [Development]  coding  "daily work"

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "auto-detect: project name is ticket pattern" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

DEV-123 - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Should auto-detect DEV-123 and do lookup *)
    [%expect {| DEV-123 - 1h  Looking up DEV-123... |}];
    http_get t (jira_issue_response ~key:"DEV-123" ~summary:"Auto-detected task" ~id:123);
    [%expect {|
      OK
        [-> DEV-123 "Auto-detected task"]
        [Enter] keep | [t] ticket | [c] category | [n] skip:
      |}];
    input t "";
    (* Description *)
    [%expect {| Description for DEV-123 (optional): |}];
    input t "auto-detected work";
    (* Category *)
    [%expect {|
      DEV-123 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    (* Summary + skip *)
    [%expect {|
      === Summary ===
      Post:
        DEV-123    (1h)  [Development]  DEV-123  "auto-detected work"

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "cached skip: override with ticket" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [("breaks", Config.Skip)] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

breaks - 30m 00s

Total: 30m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Shows skip prompt, user overrides with [t] *)
    [%expect {|
      breaks - 30m  [skip]
        [Enter] keep | [t] assign ticket:
      |}];
    input t "t";
    (* Now shows uncached prompt with search *)
    [%expect {|
        [Enter] search "breaks" | [ticket/search] | [n] skip | [S] skip always:
      |}];
    input t "BREAK-1";
    [%expect {| Looking up BREAK-1... |}];
    http_get t (jira_issue_response ~key:"BREAK-1" ~summary:"Break task" ~id:999);
    [%expect {|
        BREAK-1  Break task
        [Enter] confirm | [text] search again | [n] back:
      |}];
    input t "";
    (* Description *)
    [%expect {| Description for BREAK-1 (optional): |}];
    input t "team lunch";
    (* Category *)
    [%expect {|
      BREAK-1 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "2";
    (* Summary + skip *)
    [%expect {|
      === Summary ===
      Post:
        BREAK-1    (30m)  [Meeting]  breaks  "team lunch"

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "composite key: split tag mapping doesn't apply to standalone project" =
  with_temp_config @@ fun ~config_path ->
    (* cr:review mapped to REVIEW-55 from a previous split *)
    let config = {
      (test_config_with_mappings [
        ("cr:review", Config.Ticket "REVIEW-55");
      ]) with
      category_selections = [("REVIEW-55", "dev")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    (* Day has standalone "review" project — should NOT use cr:review mapping *)
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

review - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* review should appear as uncached — no composite key match *)
    [%expect {|
      review - 1h
        [Enter] search "review" | [ticket/search] | [n] skip | [S] skip always:
      |}];
    input t "REVIEW-99";
    [%expect {| Looking up REVIEW-99... |}];
    http_get t (jira_issue_response ~key:"REVIEW-99" ~summary:"Different review" ~id:99);
    [%expect {|
        REVIEW-99  Different review
        [Enter] confirm | [text] search again | [n] back:
      |}];
    input t "";
    [%expect {| Description for REVIEW-99 (optional): |}];
    input t "different work";
    [%expect {|
      REVIEW-99 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    [%expect {|
      === Summary ===
      Post:
        REVIEW-99  (1h)  [Development]  review  "different work"

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t
