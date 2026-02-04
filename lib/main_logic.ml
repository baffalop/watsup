open Core

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

let build_worklog_json ~ticket ~duration_seconds ~date ~description =
  let open Yojson.Safe in
  (* Note: authorAccountId is omitted - Tempo API defaults to token owner *)
  let obj = `Assoc [
    ("issueKey", `String ticket);
    ("timeSpentSeconds", `Int duration_seconds);
    ("startDate", `String date);
    ("startTime", `String "09:00:00");
    ("description", `String description);
  ] in
  to_string obj

let post_worklog ~io ~token ~ticket ~duration ~date ~description =
  let url = "https://api.tempo.io/4/worklogs" in
  let headers = [
    ("Authorization", sprintf "Bearer %s" token);
    ("Content-Type", "application/json");
  ] in
  let duration_seconds = Duration.to_seconds duration in
  let body = build_worklog_json ~ticket ~duration_seconds ~date ~description in
  io.Io.http_post ~url ~headers ~body

let run ~io ~config_path =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  (* Token check *)
  let config =
    if String.is_empty config.tempo_token then begin
      io.Io.output "Enter Tempo API token: ";
      let token = io.input () in
      { config with tempo_token = token }
    end
    else config
  in

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

      let results = List.filter_map posts ~f:(function
        | Processor.Post { ticket; duration; source = _ } ->
          let response = Lwt_main.run @@
            post_worklog ~io ~token:config.tempo_token ~ticket ~duration ~date ~description in
          let success = response.Io.status >= 200 && response.status < 300 in
          if success then
            io.output @@ sprintf "%s: OK\n" ticket
          else begin
            io.output @@ sprintf "%s: FAILED (%d)\n" ticket response.status;
            io.output @@ sprintf "  Response: %s\n" response.body
          end;
          Some success
        | Processor.Skip _ -> None)
      in

      let ok_count = List.count results ~f:Fn.id in
      let total_count = List.length results in
      io.output @@ sprintf "\nPosted %d/%d worklogs\n" ok_count total_count
    end
  end;

  Config.save ~path:config_path config |> Or_error.ok_exn
