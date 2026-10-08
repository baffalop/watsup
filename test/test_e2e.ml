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
    | effect (Io.Set_color _), k ->
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
      Mon 03 February 2026 -> Mon 03 February 2026

      coding - 1h

      Total: 1h

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
        coding     (1h)  PROJ-123  [Development]  "first run work"
      Total: 1h

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
      Mon 03 February 2026 -> Mon 03 February 2026

      coding - 1h

      breaks - 30m

      Total: 1h 30m

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
        coding     (1h)  PROJ-123  [Development]  "day one work"
      Skip:
        breaks     (30m)
      Total: 1h

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
    [%expect {|
      Tue 04 February 2026 -> Tue 04 February 2026

      coding - 2h

      breaks - 45m

      Total: 2h 45m

      coding - 2h  Looking up PROJ-123...
      |}];
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
        coding     (2h)  PROJ-123  [Development]
      Skip:
        breaks     (45m)
      Total: 2h

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
      Tue 03 February 2026 -> Tue 03 February 2026

      architecture - 25m

      breaks - 1h 20m
      [coffee   20m]
      [lunch    59m]

      cr - 51m
      [DEV-101  33m]
      [DEV-202  12m]

      Total: 2h 37m

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
    (* cr: auto-split (both tags are ticket patterns) *)
    [%expect {|
      cr - 50m
        [DEV-101  35m]
        [DEV-202  10m]
        auto-splitting
        [DEV-101  35m]   Looking up DEV-101...
      |}];
    http_get t (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
      [-> DEV-101 "Dev task 101"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t "";
    [%expect {| Description for DEV-101 (optional): |}];
    input t "review work";
    (* DEV-101 category — inline after description *)
    [%expect {|
      DEV-101 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
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
    (* DEV-202 category — inline after description *)
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
        architecture (25m)  ARCH-1  [Development]  "arch work"
        cr:DEV-101 (35m)  DEV-101  [Development]  "review work"
        cr:DEV-202 (10m)  DEV-202  [Meeting]
      Total: 1h 10m

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "cached mappings: ticket and skip (cr uncached)" =
  with_temp_config @@ fun ~config_path ->
    let config = {
      (test_config_with_mappings [
        ("architecture", Config.Ticket (Ticket.Key.of_string_exn "ARCH-1"));
        ("breaks", Config.Skip);
      ]) with
      tempo_token = "existing-token-xyz";
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* architecture: cached ticket prompt — lookup first *)
    [%expect {|
      Tue 03 February 2026 -> Tue 03 February 2026

      architecture - 25m

      breaks - 1h 20m
      [coffee   20m]
      [lunch    59m]

      cr - 51m
      [DEV-101  33m]
      [DEV-202  12m]

      Total: 2h 37m

      architecture - 25m  Looking up ARCH-1...
      |}];
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
    (* cr: auto-split (both tags are ticket patterns) *)
    [%expect {|
      cr - 50m
        [DEV-101  35m]
        [DEV-202  10m]
        auto-splitting
        [DEV-101  35m]   Looking up DEV-101...
      |}];
    http_get t (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
      [-> DEV-101 "Dev task 101"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t "";
    [%expect {| Description for DEV-101 (optional): |}];
    input t "";
    (* DEV-101 category — inline after description *)
    [%expect {|
      DEV-101 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
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
    (* DEV-202 category — inline after description *)
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
        architecture (25m)  ARCH-1  [Development]
        cr:DEV-101 (35m)  DEV-101  [Development]
        cr:DEV-202 (10m)  DEV-202  [Development]
      Skip:
        breaks     (1h 20m)
      Total: 1h 10m

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
        ("coding", Config.Ticket (Ticket.Key.of_string_exn "PROJ-123"));
        ("review", Config.Ticket (Ticket.Key.of_string_exn "PROJ-456"));
      ]) with
      issue_ids = [(Ticket.Key.of_string_exn "PROJ-123", 12345)];
      account_keys = [(Ticket.Key.of_string_exn "PROJ-123", "ACCT-1")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* coding: cached ticket prompt — lookup first *)
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      coding - 1h

      review - 30m

      Total: 1h 30m

      coding - 1h  Looking up PROJ-123...
      |}];
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
        coding     (1h)  PROJ-123  [Development]  "test work"
        review     (30m)  PROJ-456  [Development]
      Total: 1h 30m

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
        ("coding", Config.Ticket (Ticket.Key.of_string_exn "PROJ-123"));
        ("review", Config.Ticket (Ticket.Key.of_string_exn "PROJ-456"));
      ]) with
      issue_ids = [(Ticket.Key.of_string_exn "PROJ-123", 12345); (Ticket.Key.of_string_exn "PROJ-456", 67890)];
      account_keys = [(Ticket.Key.of_string_exn "PROJ-123", "ACCT-1"); (Ticket.Key.of_string_exn "PROJ-456", "ACCT-2")];
      category_selections = [(Ticket.Key.of_string_exn "PROJ-456", "dev")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* coding: cached ticket prompt — lookup first *)
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      coding - 1h

      review - 30m

      Total: 1h 30m

      coding - 1h  Looking up PROJ-123...
      |}];
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
        coding     (1h)  PROJ-123  [Meeting]
        review     (30m)  PROJ-456  [Support]
      Total: 1h 30m

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "multi-day with posting and skipping" =
  with_temp_config @@ fun ~config_path ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket (Ticket.Key.of_string_exn "PROJ-123"))]) with
      issue_ids = [(Ticket.Key.of_string_exn "PROJ-123", 12345)];
      account_keys = [(Ticket.Key.of_string_exn "PROJ-123", "ACCT-1")];
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
      Mon 03 February 2026 -> Mon 03 February 2026

      coding - 1h

      Total: 1h

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
        coding     (1h)  PROJ-123  [Development]
      Total: 1h

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    (* Day 2: cached ticket prompt — lookup first *)
    [%expect {|
      === 2026-02-04 ===
      Tue 04 February 2026 -> Tue 04 February 2026

      coding - 2h

      Total: 2h

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
        coding     (2h)  PROJ-123  [Development]
      Total: 2h

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
    (* cr: auto-split (DEV-101 and DEV-202 are ticket patterns) *)
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 1h 20m
      [DEV-101  33m]
      [review   12m]
      [DEV-202  33m]

      Total: 1h 20m

      cr - 1h 20m
        [DEV-101  35m]
        [review   10m]
        [DEV-202  35m]
        auto-splitting
        [DEV-101  35m]   Looking up DEV-101...
      |}];
    http_get t (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
      [-> DEV-101 "Dev task 101"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t "";
    [%expect {| Description for DEV-101 (optional): |}];
    input t "review of DEV-101";
    (* DEV-101 category — inline after description *)
    [%expect {|
      DEV-101 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    (* review: uncached non-ticket tag, skip always *)
    [%expect {| [review   10m]   [Enter] search "cr review" | [ticket/search] | [n] skip | [S] skip always: |}];
    input t "S";
    (* DEV-202: auto-detected ticket pattern, lookup *)
    [%expect {| [DEV-202  35m]   Looking up DEV-202... |}];
    http_get t (jira_issue_response ~key:"DEV-202" ~summary:"Dev task 202" ~id:202);
    [%expect {|
      OK
      [-> DEV-202 "Dev task 202"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t "n";
    [%expect {|
      === Summary ===
      Post:
        cr:DEV-101 (35m)  DEV-101  [Development]  "review of DEV-101"
      Total: 35m

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
      Mon 03 February 2026 -> Mon 03 February 2026

      Total: 0m

      === Summary ===
      |}];
    finish t

let%expect_test "cached ticket: keep all" =
  with_temp_config @@ fun ~config_path ->
    let config = {
      (test_config_with_mappings [("coding", Config.Ticket (Ticket.Key.of_string_exn "PROJ-123"))]) with
      category_selections = [(Ticket.Key.of_string_exn "PROJ-123", "dev")];
    } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Context + cached prompt: lookup first *)
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      coding - 1h

      Total: 1h

      coding - 1h  Looking up PROJ-123...
      |}];
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
        coding     (1h)  PROJ-123  [Development]  "daily work"
      Total: 1h

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
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      DEV-123 - 1h

      Total: 1h

      DEV-123 - 1h  Looking up DEV-123...
      |}];
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
        DEV-123    (1h)  DEV-123  [Development]  "auto-detected work"
      Total: 1h

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
      Mon 03 February 2026 -> Mon 03 February 2026

      breaks - 30m

      Total: 30m

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
        breaks     (30m)  BREAK-1  [Meeting]  "team lunch"
      Total: 30m

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
        ("cr:review", Config.Ticket (Ticket.Key.of_string_exn "REVIEW-55"));
      ]) with
      category_selections = [(Ticket.Key.of_string_exn "REVIEW-55", "dev")];
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
      Mon 03 February 2026 -> Mon 03 February 2026

      review - 1h

      Total: 1h

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
        review     (1h)  REVIEW-99  [Development]  "different work"
      Total: 1h

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

let%expect_test "split mappings persist across runs" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 1h 20m 00s
	[DEV-101     40m 00s]
	[DEV-202     40m 00s]

Total: 1h 20m 00s|} in
    (* Run 1: auto-split, user keeps both DEV-101 and DEV-202 *)
    let t1 = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 1h 20m
      [DEV-101  40m]
      [DEV-202  40m]

      Total: 1h 20m

      cr - 1h 20m
        [DEV-101  40m]
        [DEV-202  40m]
        auto-splitting
        [DEV-101  40m]   Looking up DEV-101...
      |}];
    http_get t1 (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
      [-> DEV-101 "Dev task 101"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t1 "";   (* keep *)
    [%expect {| Description for DEV-101 (optional): |}];
    input t1 "";   (* description *)
    [%expect {|
      DEV-101 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t1 "1";  (* category: Development *)
    http_get t1 (jira_issue_response ~key:"DEV-202" ~summary:"Dev task 202" ~id:202);
    [%expect {|
        [DEV-202  40m]   Looking up DEV-202... OK
      [-> DEV-202 "Dev task 202"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t1 "";   (* keep *)
    [%expect {| Description for DEV-202 (optional): |}];
    input t1 "";   (* description *)
    [%expect {|
      DEV-202 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t1 "1";  (* category: Development *)
    [%expect {|
      === Summary ===
      Post:
        cr:DEV-101 (40m)  DEV-101  [Development]
        cr:DEV-202 (40m)  DEV-202  [Development]
      Total: 1h 20m

      [Enter] post | [n] skip day:
      |}];
    input t1 "n";  (* skip day *)
    [%expect {||}];
    finish t1;
    (* Verify composite keys were persisted to disk *)
    let saved1 = Config.load ~path:config_path |> Or_error.ok_exn in
    let has_dev101 = Option.is_some (Config.get_mapping saved1 "cr:DEV-101") in
    let has_dev202 = Option.is_some (Config.get_mapping saved1 "cr:DEV-202") in
    printf "cr:DEV-101: %b, cr:DEV-202: %b\n" has_dev101 has_dev202;
    [%expect {| cr:DEV-101: true, cr:DEV-202: true |}];
    (* Run 2: composite keys should be in config -> auto-split with cached prompts *)
    let t2 = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 1h 20m
      [DEV-101  40m]
      [DEV-202  40m]

      Total: 1h 20m

      cr - 1h 20m
        [DEV-101  40m]
        [DEV-202  40m]
        auto-splitting
        [DEV-101  40m]   Looking up DEV-101...
      |}];
    (* cached_tag always re-validates the ticket via Jira lookup, even when the composite
       key is in config — no reduction in HTTP calls vs. an uncached run *)
    http_get t2 (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
      [-> DEV-101 "Dev task 101"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t2 "";   (* keep *)
    [%expect {| Description for DEV-101 (optional): |}];
    input t2 "";   (* description *)
    [%expect {|
      DEV-101 category: Development
        [Enter] keep | [c] change:
      |}];
    input t2 "";  (* keep category *)
    http_get t2 (jira_issue_response ~key:"DEV-202" ~summary:"Dev task 202" ~id:202);
    [%expect {|
        [DEV-202  40m]   Looking up DEV-202... OK
      [-> DEV-202 "Dev task 202"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t2 "";   (* keep *)
    [%expect {| Description for DEV-202 (optional): |}];
    input t2 "";   (* description *)
    [%expect {|
      DEV-202 category: Development
        [Enter] keep | [c] change:
      |}];
    input t2 "";  (* keep category *)
    [%expect {|
      === Summary ===
      Post:
        cr:DEV-101 (40m)  DEV-101  [Development]
        cr:DEV-202 (40m)  DEV-202  [Development]
      Total: 1h 20m

      [Enter] post | [n] skip day:
      |}];
    input t2 "n";
    [%expect {||}];
    finish t2

let%expect_test "split after project-level mapping: clears project key, saves composite" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings
      [("cr", Config.Ticket (Ticket.Key.of_string_exn "PROJ-1"))] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 1h 20m 00s
	[DEV-101     40m 00s]
	[DEV-202     40m 00s]

Total: 1h 20m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* cr: cached ticket PROJ-1, lookup first *)
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 1h 20m
      [DEV-101  40m]
      [DEV-202  40m]

      Total: 1h 20m

      cr - 1h 20m
        [DEV-101  40m]
        [DEV-202  40m]
        Looking up PROJ-1...
      |}];
    http_get t (jira_issue_response ~key:"PROJ-1" ~summary:"Project one" ~id:11);
    [%expect {|
      OK
        [-> PROJ-1 "Project one"]
        [Enter] keep | [t] ticket | [s] split | [c] category | [n] skip:
      |}];
    input t "s";   (* [s] split *)
    (* DEV-101: auto-inferred ticket pattern *)
    [%expect {| [DEV-101  40m]   Looking up DEV-101... |}];
    http_get t (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
      [-> DEV-101 "Dev task 101"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t "";   (* keep *)
    [%expect {| Description for DEV-101 (optional): |}];
    input t "";   (* description *)
    [%expect {|
      DEV-101 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";  (* category *)
    (* DEV-202: auto-inferred ticket pattern *)
    [%expect {| [DEV-202  40m]   Looking up DEV-202... |}];
    http_get t (jira_issue_response ~key:"DEV-202" ~summary:"Dev task 202" ~id:202);
    [%expect {|
      OK
      [-> DEV-202 "Dev task 202"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t "";   (* keep *)
    [%expect {| Description for DEV-202 (optional): |}];
    input t "";   (* description *)
    [%expect {|
      DEV-202 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";  (* category *)
    [%expect {|
      === Summary ===
      Post:
        cr:DEV-101 (40m)  DEV-101  [Development]
        cr:DEV-202 (40m)  DEV-202  [Development]
      Total: 1h 20m

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t;
    (* Verify config: cr:DEV-101 and cr:DEV-202 saved, but cr NOT present *)
    let saved = Config.load ~path:config_path |> Or_error.ok_exn in
    let has_cr = Option.is_some (Config.get_mapping saved "cr") in
    let has_cr_dev101 = Option.is_some (Config.get_mapping saved "cr:DEV-101") in
    let has_cr_dev202 = Option.is_some (Config.get_mapping saved "cr:DEV-202") in
    printf "cr: %b, cr:DEV-101: %b, cr:DEV-202: %b\n" has_cr has_cr_dev101 has_cr_dev202;
    [%expect {| cr: false, cr:DEV-101: true, cr:DEV-202: true |}]

let%expect_test "multi-day: split -> single-tag day -> new tag -> split again -> autosplit" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson_feature_review = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 1h 20m 00s
	[feature     40m 00s]
	[review      40m 00s]

Total: 1h 20m 00s|} in
    let watson_feature_only = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 40m 00s
	[feature     40m 00s]

Total: 40m 00s|} in
    let watson_feature_newwork = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 1h 20m 00s
	[feature     40m 00s]
	[newwork     40m 00s]

Total: 1h 20m 00s|} in

    (* Day 1: uncached entry, user splits and maps both tags *)
    let t1 = start ~watson_output:[(test_date, watson_feature_review)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 1h 20m
      [feature  40m]
      [review   40m]

      Total: 1h 20m

      cr - 1h 20m
        [feature  40m]
        [review   40m]

        [Enter] search "cr feature review" | [ticket/search] | [s] split | [n] skip | [S] skip always:
      |}];
    input t1 "s";         (* split from uncached entry prompt *)
    [%expect {| [feature  40m]   [Enter] search "cr feature" | [ticket/search] | [n] skip | [S] skip always: |}];      (* feature: uncached_tag prompt *)
    input t1 "FEAT-1";
    [%expect {| Looking up FEAT-1... |}];      (* Looking up FEAT-1... *)
    http_get t1 (jira_issue_response ~key:"FEAT-1" ~summary:"Feature work" ~id:1);
    [%expect {|
      FEAT-1  Feature work
      [Enter] confirm | [text] search again | [n] back:
      |}];      (* result + confirm *)
    input t1 "";          (* confirm *)
    [%expect {| Description for FEAT-1 (optional): |}];      (* description *)
    input t1 "";
    [%expect {|
      FEAT-1 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];      (* category: fresh *)
    input t1 "1";         (* Development *)
    [%expect {| [review   40m]   [Enter] search "cr review" | [ticket/search] | [n] skip | [S] skip always: |}];      (* review: uncached_tag prompt *)
    input t1 "REV-1";
    [%expect {| Looking up REV-1... |}];      (* Looking up REV-1... *)
    http_get t1 (jira_issue_response ~key:"REV-1" ~summary:"Review work" ~id:2);
    [%expect {|
      REV-1  Review work
      [Enter] confirm | [text] search again | [n] back:
      |}];      (* result + confirm *)
    input t1 "";          (* confirm *)
    [%expect {| Description for REV-1 (optional): |}];      (* description *)
    input t1 "";
    [%expect {|
      REV-1 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];      (* category: fresh *)
    input t1 "1";         (* Development *)
    [%expect {|
      === Summary ===
      Post:
        cr:feature (40m)  FEAT-1  [Development]
        cr:review  (40m)  REV-1  [Development]
      Total: 1h 20m

      [Enter] post | [n] skip day:
      |}];      (* summary *)
    input t1 "n";
    [%expect {| |}];
    finish t1;

    (* Day 2: only [feature] tag present — one composite key matches -> Tag_inferred *)
    let t2 = start ~watson_output:[(test_date, watson_feature_only)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 40m
      [feature  40m]

      Total: 40m

      cr - 40m
        [feature  40m]
        Looking up FEAT-1...
      |}];      (* entry context + Looking up FEAT-1... *)
    http_get t2 (jira_issue_response ~key:"FEAT-1" ~summary:"Feature work" ~id:1);
    [%expect {|
      OK
        [-> FEAT-1 "Feature work"]
        [Enter] keep | [t] ticket | [s] split | [c] category | [n] skip:
      |}];      (* OK + project-level cached prompt (Tag_inferred looks identical) *)
    input t2 "";          (* keep -> saves cr -> FEAT-1 at project level *)
    [%expect {| Description for FEAT-1 (optional): |}];      (* description *)
    input t2 "";
    [%expect {|
      FEAT-1 category: Development
        [Enter] keep | [c] change:
      |}];      (* category: cached keep/change *)
    input t2 "";          (* keep *)
    [%expect {|
      === Summary ===
      Post:
        cr         (40m)  FEAT-1  [Development]
      Total: 40m

      [Enter] post | [n] skip day:
      |}];      (* summary *)
    input t2 "n";
    [%expect {| |}];
    finish t2;

    (* Day 3: [feature, newwork] — project-level cr -> FEAT-1 now in effect *)
    let t3 = start ~watson_output:[(test_date, watson_feature_newwork)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 1h 20m
      [feature  40m]
      [newwork  40m]

      Total: 1h 20m

      cr - 1h 20m
        [feature  40m]
        [newwork  40m]
        Looking up FEAT-1...
      |}];      (* entry context + Looking up FEAT-1... *)
    http_get t3 (jira_issue_response ~key:"FEAT-1" ~summary:"Feature work" ~id:1);
    [%expect {|
      OK
        [-> FEAT-1 "Feature work"]
        [Enter] keep | [t] ticket | [s] split | [c] category | [n] skip:
      |}];      (* OK + project-level cached prompt, [s] split available *)
    input t3 "";          (* keep -> all 1h 20m (feature + newwork) posted to FEAT-1 *)
    [%expect {| Description for FEAT-1 (optional): |}];      (* description *)
    input t3 "";
    [%expect {|
      FEAT-1 category: Development
        [Enter] keep | [c] change:
      |}];      (* category: change to Meeting *)
    input t3 "c";
    [%expect {|
        1. Development *
        2. Meeting
        3. Support
      >
      |}];      (* category list *)
    input t3 "2";         (* Meeting *)
    [%expect {|
      === Summary ===
      Post:
        cr         (1h 20m)  FEAT-1  [Meeting]
      Total: 1h 20m

      [Enter] post | [n] skip day:
      |}];      (* summary: cr (1h 20m) -> FEAT-1 [Meeting], newwork time silently absorbed *)
    input t3 "n";
    [%expect {| |}];
    finish t3;

    (* Day 4: same tags — user splits, keeps FEAT-1 for feature, assigns TASK-1 for newwork *)
    let t4 = start ~watson_output:[(test_date, watson_feature_newwork)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 1h 20m
      [feature  40m]
      [newwork  40m]

      Total: 1h 20m

      cr - 1h 20m
        [feature  40m]
        [newwork  40m]
        Looking up FEAT-1...
      |}];      (* entry context + Looking up FEAT-1... *)
    http_get t4 (jira_issue_response ~key:"FEAT-1" ~summary:"Feature work" ~id:1);
    [%expect {|
      OK
        [-> FEAT-1 "Feature work"]
        [Enter] keep | [t] ticket | [s] split | [c] category | [n] skip:
      |}];
    input t4 "s";         (* split *)
    (* feature: cached composite key cr:feature -> FEAT-1, cached_tag prompt *)
    http_get t4 (jira_issue_response ~key:"FEAT-1" ~summary:"Feature work" ~id:1);
    [%expect {|
        [feature  40m]   Looking up FEAT-1... OK
      [-> FEAT-1 "Feature work"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t4 "";          (* keep *)
    [%expect {| Description for FEAT-1 (optional): |}];      (* description *)
    input t4 "";
    [%expect {|
      FEAT-1 category: Meeting
        [Enter] keep | [c] change:
      |}];      (* category: cached keep/change — Meeting or Development? *)
    input t4 "";          (* keep *)
    (* newwork: uncached, no composite key -> uncached_tag search *)
    [%expect {| [newwork  40m]   [Enter] search "cr newwork" | [ticket/search] | [n] skip | [S] skip always: |}];
    input t4 "TASK-1";
    [%expect {| Looking up TASK-1... |}];      (* Looking up TASK-1... *)
    http_get t4 (jira_issue_response ~key:"TASK-1" ~summary:"Task one" ~id:3);
    [%expect {|
      TASK-1  Task one
      [Enter] confirm | [text] search again | [n] back:
      |}];      (* result + confirm *)
    input t4 "";          (* confirm *)
    [%expect {| Description for TASK-1 (optional): |}];      (* description *)
    input t4 "";
    [%expect {|
      TASK-1 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];      (* category: fresh *)
    input t4 "1";         (* Development *)
    [%expect {|
      === Summary ===
      Post:
        cr:feature (40m)  FEAT-1  [Meeting]
        cr:newwork (40m)  TASK-1  [Development]
      Total: 1h 20m

      [Enter] post | [n] skip day:
      |}];      (* summary *)
    input t4 "n";
    [%expect {| |}];
    finish t4;

    (* Day 5: same tags — both composite keys exist -> Auto_split *)
    let t5 = start ~watson_output:[(test_date, watson_feature_newwork)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* feature: cached_tag lookup *)
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 1h 20m
      [feature  40m]
      [newwork  40m]

      Total: 1h 20m

      cr - 1h 20m
        [feature  40m]
        [newwork  40m]
        auto-splitting
        [feature  40m]   Looking up FEAT-1...
      |}];
    http_get t5 (jira_issue_response ~key:"FEAT-1" ~summary:"Feature work" ~id:1);
    [%expect {|
      OK
      [-> FEAT-1 "Feature work"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t5 "";          (* keep *)
    [%expect {| Description for FEAT-1 (optional): |}];      (* description *)
    input t5 "";
    [%expect {|
      FEAT-1 category: Meeting
        [Enter] keep | [c] change:
      |}];      (* category: change to Support to test reverse direction (split -> project-level) *)
    input t5 "c";
    [%expect {|
        1. Development
        2. Meeting *
        3. Support
      >
      |}];      (* category list with Meeting marked *)
    input t5 "3";         (* Support *)
    (* newwork: cached_tag lookup *)
    http_get t5 (jira_issue_response ~key:"TASK-1" ~summary:"Task one" ~id:3);
    [%expect {|
        [newwork  40m]   Looking up TASK-1... OK
      [-> TASK-1 "Task one"] [Enter] keep | [t] change | [n] skip:
      |}];
    input t5 "";          (* keep *)
    [%expect {| Description for TASK-1 (optional): |}];      (* description *)
    input t5 "";
    [%expect {|
      TASK-1 category: Development
        [Enter] keep | [c] change:
      |}];      (* category: cached keep/change *)
    input t5 "";          (* keep *)
    [%expect {|
      === Summary ===
      Post:
        cr:feature (40m)  FEAT-1  [Support]
        cr:newwork (40m)  TASK-1  [Development]
      Total: 1h 20m

      [Enter] post | [n] skip day:
      |}];      (* summary *)
    input t5 "n";
    [%expect {| |}];
    finish t5;

    (* Day 6: only [feature] -> Tag_inferred FEAT-1.
       Category changed during split path (Day 5) should carry through to project-level path. *)
    let t6 = start ~watson_output:[(test_date, watson_feature_only)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 40m
      [feature  40m]

      Total: 40m

      cr - 40m
        [feature  40m]
        Looking up FEAT-1...
      |}];
    http_get t6 (jira_issue_response ~key:"FEAT-1" ~summary:"Feature work" ~id:1);
    [%expect {|
      OK
        [-> FEAT-1 "Feature work"]
        [Enter] keep | [t] ticket | [s] split | [c] category | [n] skip:
      |}];
    input t6 "";          (* keep *)
    [%expect {| Description for FEAT-1 (optional): |}];      (* description *)
    input t6 "";
    [%expect {|
      FEAT-1 category: Support
        [Enter] keep | [c] change:
      |}];      (* category: Support or Meeting? *)
    input t6 "";          (* keep *)
    [%expect {|
      === Summary ===
      Post:
        cr         (40m)  FEAT-1  [Support]
      Total: 40m

      [Enter] post | [n] skip day:
      |}];      (* summary *)
    input t6 "n";
    [%expect {| |}];
    finish t6

let%expect_test "cached ticket lookup failure: clears mapping, falls through to search" =
  with_temp_config @@ fun ~config_path ->
    let config = test_config_with_mappings [("coding", Config.Ticket (Ticket.Key.of_string_exn "OLD-1"))] in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    let watson = {|Mon 03 February 2026 -> Mon 03 February 2026

coding - 1h 00m 00s

Total: 1h 00m 00s|} in
    let t = start ~watson_output:[(test_date, watson)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Cached ticket lookup returns 404 *)
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      coding - 1h

      Total: 1h

      coding - 1h  Looking up OLD-1...
      |}];
    http_get t { Io.status = 404; body = "Not Found" };
    (* Lookup failed -> falls through to uncached search prompt *)
    [%expect {|
      not found (404)

        [Enter] search "coding" | [ticket/search] | [n] skip | [S] skip always:
      |}];
    (* User searches and picks a different ticket *)
    input t "NEW-99";
    [%expect {| Looking up NEW-99... |}];
    http_get t (jira_issue_response ~key:"NEW-99" ~summary:"Replacement task" ~id:99);
    [%expect {|
      NEW-99  Replacement task
      [Enter] confirm | [text] search again | [n] back:
      |}];
    input t "";
    [%expect {| Description for NEW-99 (optional): |}];
    input t "new work";
    (* Category *)
    [%expect {|
      NEW-99 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t "1";
    (* Summary *)
    [%expect {|
      === Summary ===
      Post:
        coding     (1h)  NEW-99  [Development]  "new work"
      Total: 1h

      [Enter] post | [n] skip day:
      |}];
    input t "n";
    [%expect {||}];
    finish t

(* ── Bug reproduction tests ──────────────────────────────────────────────── *)

(* Bug 1: when a project has composite-key mappings from a previous split,
   encountering that project with only one matching tag produces Tag_inferred.
   Keeping in Tag_inferred saves a project-level mapping (entry.Watson.project)
   which then takes precedence over the composite keys on the next multi-tag run,
   causing Project_cached to fire instead of Auto_split. *)
let%expect_test "bug: tag-inferred keep saves project key, overriding composite keys" =
  with_temp_config @@ fun ~config_path ->
    (* Start with composite keys from a previous split run *)
    let config = test_config_with_mappings [
      ("cr:DEV-101", Config.Ticket (Ticket.Key.of_string_exn "DEV-101"));
      ("cr:DEV-202", Config.Ticket (Ticket.Key.of_string_exn "DEV-202"));
    ] in
    Config.save ~path:config_path config |> Or_error.ok_exn;

    (* Run 1: only [DEV-101] present -> Tag_inferred DEV-101 -> user keeps
       This incorrectly saves cr -> DEV-101 at the project level. *)
    let watson_single = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 40m 00s
	[DEV-101     40m 00s]

Total: 40m 00s|} in
    let t1 = start ~watson_output:[(test_date, watson_single)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 40m
      [DEV-101  40m]

      Total: 40m

      cr - 40m
        [DEV-101  40m]
        Looking up DEV-101...
      |}];
    http_get t1 (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
        [-> DEV-101 "Dev task 101"]
        [Enter] keep | [t] ticket | [s] split | [c] category | [n] skip:
      |}];
    input t1 "";   (* keep *)
    [%expect {| Description for DEV-101 (optional): |}];
    input t1 "";   (* description *)
    [%expect {|
      DEV-101 category:
        1. Development
        2. Meeting
        3. Support
      >
      |}];
    input t1 "1";  (* category: Development (fresh, no prior selection) *)
    [%expect {|
      === Summary ===
      Post:
        cr         (40m)  DEV-101  [Development]
      Total: 40m

      [Enter] post | [n] skip day:
      |}];
    input t1 "n";  (* skip posting *)
    [%expect {||}];
    finish t1;

    (* Verify bug: project-level 'cr' mapping now exists alongside composite keys *)
    let saved1 = Config.load ~path:config_path |> Or_error.ok_exn in
    printf "after single-tag run - cr: %b, cr:DEV-101: %b, cr:DEV-202: %b\n"
      (Option.is_some (Config.get_mapping saved1 "cr"))
      (Option.is_some (Config.get_mapping saved1 "cr:DEV-101"))
      (Option.is_some (Config.get_mapping saved1 "cr:DEV-202"));
    (* Bug: cr is true — project-level mapping was saved and will override composite keys *)
    [%expect {| after single-tag run - cr: true, cr:DEV-101: true, cr:DEV-202: true |}];

    (* Run 2: both tags present -> should Auto_split on composite keys,
       but project-level 'cr -> DEV-101' causes Project_cached DEV-101 instead. *)
    let watson_both = {|Mon 03 February 2026 -> Mon 03 February 2026

cr - 1h 20m 00s
	[DEV-101     40m 00s]
	[DEV-202     40m 00s]

Total: 1h 20m 00s|} in
    let t2 = start ~watson_output:[(test_date, watson_both)] ~config_path (fun () ->
      Main_logic.run ~config_path ~dates:[test_date])
    in
    (* Bug: output shows project-level cached prompt for DEV-101 (1h 20m total),
       NOT "auto-splitting" with per-tag prompts. *)
    [%expect {|
      Mon 03 February 2026 -> Mon 03 February 2026

      cr - 1h 20m
      [DEV-101  40m]
      [DEV-202  40m]

      Total: 1h 20m

      cr - 1h 20m
        [DEV-101  40m]
        [DEV-202  40m]
        Looking up DEV-101...
      |}];
    http_get t2 (jira_issue_response ~key:"DEV-101" ~summary:"Dev task 101" ~id:101);
    [%expect {|
      OK
        [-> DEV-101 "Dev task 101"]
        [Enter] keep | [t] ticket | [s] split | [c] category | [n] skip:
      |}];
    input t2 "n";   (* skip *)
    [%expect {| === Summary === |}];
    finish t2

