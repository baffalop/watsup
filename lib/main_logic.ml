open Core

(* Jira API helpers *)
let jira_auth_header ~email ~token =
  let credentials = sprintf "%s:%s" email token in
  let encoded = Base64.encode_exn credentials in
  ("Authorization", sprintf "Basic %s" encoded)

let fetch_jira_account_id ~io ~config =
  let url = sprintf "%s/rest/api/2/myself" config.Config.jira_base_url in
  let headers = [
    jira_auth_header ~email:config.jira_email ~token:config.jira_token;
    ("Accept", "application/json");
  ] in
  let response = Lwt_main.run @@ io.Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    let json = Yojson.Safe.from_string response.body in
    match Yojson.Safe.Util.member "accountId" json with
    | `String account_id -> Ok account_id
    | _ -> Error "accountId not found in response"
  else
    Error (sprintf "Jira API error (%d): %s" response.status response.body)

let fetch_jira_issue_id ~io ~config ~ticket =
  let url = sprintf "%s/rest/api/2/issue/%s?fields=id" config.Config.jira_base_url ticket in
  let headers = [
    jira_auth_header ~email:config.jira_email ~token:config.jira_token;
    ("Accept", "application/json");
  ] in
  let response = Lwt_main.run @@ io.Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    let json = Yojson.Safe.from_string response.body in
    match Yojson.Safe.Util.member "id" json with
    | `String id_str -> Ok (Int.of_string id_str)
    | _ -> Error "id not found in response"
  else
    Error (sprintf "Jira API error (%d): %s" response.status response.body)

let prompt_for_entry ~io entry =
  io.Io.output @@ sprintf "\n%s - %s\n"
    entry.Watson.project
    (Duration.to_string @@ Duration.round_5min entry.total);
  io.output "  [ticket] assign | [n] skip | [S] skip always: ";
  let input = io.input () in
  match input with
  | "n" -> Processor.Skip_once
  | "S" -> Processor.Skip_always
  | ticket -> Processor.Accept ticket

(* Parse date from Watson date_range like "Tue 03 February 2026 -> Tue 03 February 2026" *)
let parse_date_from_range date_range =
  (* Extract first date before " -> " *)
  let first_date = String.lsplit2_exn date_range ~on:'-'
    |> fst
    |> String.rstrip ~drop:(Char.equal ' ')
    |> String.rstrip ~drop:(Char.equal ' ')
  in
  (* Parse "Tue 03 February 2026" format *)
  let parts = String.split first_date ~on:' ' in
  match parts with
  | [_dow; day; month_name; year] ->
    let month = match String.lowercase month_name with
      | "january" -> 1 | "february" -> 2 | "march" -> 3 | "april" -> 4
      | "may" -> 5 | "june" -> 6 | "july" -> 7 | "august" -> 8
      | "september" -> 9 | "october" -> 10 | "november" -> 11 | "december" -> 12
      | _ -> failwith @@ sprintf "Unknown month: %s" month_name
    in
    sprintf "%s-%02d-%s" year month day
  | _ -> failwith @@ sprintf "Cannot parse date: %s" first_date

let build_worklog_json ~issue_id ~author_account_id ~duration_seconds ~date ~description =
  let open Yojson.Safe in
  let obj = `Assoc [
    ("issueId", `Int issue_id);
    ("authorAccountId", `String author_account_id);
    ("timeSpentSeconds", `Int duration_seconds);
    ("startDate", `String date);
    ("startTime", `String "09:00:00");
    ("description", `String description);
  ] in
  to_string obj

let post_worklog ~io ~token ~issue_id ~author_account_id ~duration ~date ~description =
  let url = "https://api.tempo.io/4/worklogs" in
  let headers = [
    ("Authorization", sprintf "Bearer %s" token);
    ("Content-Type", "application/json");
  ] in
  let duration_seconds = Duration.to_seconds duration in
  let body = build_worklog_json ~issue_id ~author_account_id ~duration_seconds ~date ~description in
  io.Io.http_post ~url ~headers ~body

let run ~io ~config_path =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  (* Credential prompts *)
  let config =
    if String.is_empty config.tempo_token then begin
      io.Io.output "Enter Tempo API token: ";
      let token = io.input_secret () in
      { config with tempo_token = token }
    end
    else config
  in

  let config =
    if String.is_empty config.jira_base_url then begin
      io.Io.output "Enter Jira base URL (e.g., https://company.atlassian.net): ";
      let url = io.input () in
      { config with jira_base_url = url }
    end
    else config
  in

  let config =
    if String.is_empty config.jira_email then begin
      io.Io.output "Enter Jira email: ";
      let email = io.input () in
      { config with jira_email = email }
    end
    else config
  in

  let config =
    if String.is_empty config.jira_token then begin
      io.Io.output "Enter Jira API token: ";
      let token = io.input_secret () in
      { config with jira_token = token }
    end
    else config
  in

  (* Fetch Jira account ID if not cached *)
  let config =
    if String.is_empty config.jira_account_id then begin
      io.Io.output "Fetching Jira account ID... ";
      match fetch_jira_account_id ~io ~config with
      | Ok account_id ->
        io.output @@ sprintf "OK (%s)\n" account_id;
        { config with jira_account_id = account_id }
      | Error msg ->
        io.output @@ sprintf "FAILED: %s\n" msg;
        failwith "Could not fetch Jira account ID"
    end
    else config
  in

  (* Save config after credential collection *)
  Config.save ~path:config_path config |> Or_error.ok_exn;

  (* Parse watson report *)
  let watson_output = io.run_command "watson report -dG" in
  let report = Watson.parse watson_output |> Or_error.ok_exn in

  io.output @@ sprintf "Report: %s (%d entries)\n"
    report.date_range (List.length report.entries);

  (* Process each entry - using fold for O(n) instead of O(n²) append *)
  let all_decisions, config =
    List.fold report.entries ~init:([], config) ~f:(fun (acc_decisions, cfg) entry ->
      let cached = Config.get_mapping cfg entry.project in
      let decisions, new_mapping = Processor.process_entry
        ~entry ~cached
        ~prompt:(prompt_for_entry ~io) in
      let cfg' = Option.value_map new_mapping ~default:cfg
        ~f:(fun m -> Config.set_mapping cfg entry.project m) in
      (List.rev_append decisions acc_decisions, cfg'))
  in
  let all_decisions = List.rev all_decisions in

  (* Summary *)
  io.output "\n=== Summary ===\n";
  let posts, skips = List.partition_tf all_decisions ~f:(function
    | Processor.Post _ -> true
    | Processor.Skip _ -> false) in

  List.iter posts ~f:(function
    | Processor.Post { ticket; duration; source } ->
      io.output @@ sprintf "POST: %s (%s) from %s\n" ticket (Duration.to_string duration) source
    | Processor.Skip _ -> ());

  List.iter skips ~f:(function
    | Processor.Skip { project; duration } ->
      io.output @@ sprintf "SKIP: %s (%s)\n" project (Duration.to_string duration)
    | Processor.Post _ -> ());

  (* If there are posts, ask for confirmation and post to Tempo *)
  if not (List.is_empty posts) then begin
    io.output "\n=== Worklogs to Post ===\n";
    List.iter posts ~f:(function
      | Processor.Post { ticket; duration; source = _ } ->
        io.output @@ sprintf "  %s: %s\n" ticket (Duration.to_string duration)
      | Processor.Skip _ -> ());

    io.output "\nDescription (optional): ";
    let description = io.input () in

    io.output "[Enter] post | [q] quit: ";
    let confirm = io.input () in

    if not (String.equal confirm "q") then begin
      let date = parse_date_from_range report.date_range in
      io.output "\n=== Posting ===\n";

      (* Resolve issue IDs and post worklogs, accumulating config changes *)
      let results, config =
        List.fold posts ~init:([], config) ~f:(fun (acc, cfg) decision ->
          match decision with
          | Processor.Post { ticket; duration; source = _ } ->
            (* Look up or fetch issue ID *)
            let issue_id, cfg =
              match Config.get_issue_id cfg ticket with
              | Some id -> (id, cfg)
              | None ->
                io.output @@ sprintf "  Looking up %s... " ticket;
                match fetch_jira_issue_id ~io ~config:cfg ~ticket with
                | Ok id ->
                  io.output @@ sprintf "OK (%d)\n" id;
                  (id, Config.set_issue_id cfg ticket id)
                | Error msg ->
                  io.output @@ sprintf "FAILED: %s\n" msg;
                  failwith @@ sprintf "Could not fetch issue ID for %s" ticket
            in
            let response = Lwt_main.run @@
              post_worklog ~io ~token:cfg.tempo_token
                ~issue_id ~author_account_id:cfg.jira_account_id
                ~duration ~date ~description in
            let success = response.Io.status >= 200 && response.status < 300 in
            if success then
              io.output @@ sprintf "%s: OK\n" ticket
            else begin
              io.output @@ sprintf "%s: FAILED (%d)\n" ticket response.status;
              io.output @@ sprintf "  Response: %s\n" response.body
            end;
            (success :: acc, cfg)
          | Processor.Skip _ -> (acc, cfg))
      in

      let ok_count = List.count results ~f:Fn.id in
      let total_count = List.length results in
      io.output @@ sprintf "\nPosted %d/%d worklogs\n" ok_count total_count;
      (* Save config with cached issue IDs *)
      Config.save ~path:config_path config |> Or_error.ok_exn
    end
    else
      Config.save ~path:config_path config |> Or_error.ok_exn
  end
  else
    Config.save ~path:config_path config |> Or_error.ok_exn
