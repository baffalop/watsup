open Core

let show_entry_context entry =
  let has_tags = not (List.is_empty entry.Watson.tags) in
  Io.styled @@ sprintf "\n{project}%s{/} - {duration}%s{/}"
    entry.project
    (Duration.to_string @@ Duration.round_5min entry.total);
  if has_tags then begin
    Io.output "\n";
    List.iter entry.tags ~f:(fun tag ->
      Io.styled @@ sprintf "  [{tag}%-8s{/} {duration}%s{/}]\n" tag.Watson.name
        (Duration.to_string @@ Duration.round_5min tag.duration))
  end

(* Parse date from Watson date_range like "Tue 03 February 2026 -> Tue 03 February 2026" *)
let parse_date_from_range date_range =
  (* Extract first date before " -> " separator *)
  let first_date = match String.lsplit2 date_range ~on:'>' with
    | Some (before_arrow, _) -> String.rstrip before_arrow ~drop:(fun c -> Char.equal c ' ' || Char.equal c '-')
    | None -> failwith @@ sprintf "Cannot find ' -> ' separator in: %s" date_range
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

let%expect_test "parse_date_from_range" =
  let test s = print_endline @@ parse_date_from_range s in
  test "Tue 03 February 2026 -> Tue 03 February 2026";
  [%expect {| 2026-02-03 |}];
  test "Mon 15 January 2026 -> Fri 19 January 2026";
  [%expect {| 2026-01-15 |}]

let resolve_category_for_display ~config ~options ticket =
  match Config.get_category_selection config ticket with
  | Some value ->
    List.find options ~f:(fun cat -> String.equal (Category.value cat) value)
  | None -> None

let display_watson_report report =
  Io.styled @@ sprintf "{info}%s{/}\n\n" report.Watson.date_range;
  List.iter report.entries ~f:(fun entry ->
    Io.styled @@ sprintf "{project}%s{/} - {duration}%s{/}\n"
      entry.Watson.project
      (Duration.to_string entry.total);
    List.iter entry.tags ~f:(fun tag ->
      Io.styled @@ sprintf "\t[{tag}%-8s{/} {duration}%s{/}]\n" tag.Watson.name
        (Duration.to_string tag.duration));
    Io.output "\n");
  Io.styled @@ sprintf "{header}Total: {duration}%s{/}\n" (Duration.to_string report.total)

let run_styled f =
  let open Effect.Deep in
  try f () with
  | effect (Io.Output s), k -> print_string s; continue k ()
  | effect (Io.Set_color c), k ->
    let tag = match c with
      | Io.Reset -> "/)" | Bold -> "(B" | Dim -> "(D" | Red -> "(R"
      | Green -> "(G" | Yellow -> "(Y" | Blue -> "(U" | Cyan -> "(C"
    in
    print_string tag; continue k ()

let%expect_test "display_watson_report: entries with tags" =
  let report = {
    Watson.date_range = "Tue 03 February 2026 -> Tue 03 February 2026";
    entries = [
      { project = "coding"; total = Duration.of_hms ~hours:1 ~mins:30 ~secs:0; tags = [] };
      { project = "cr"; total = Duration.of_hms ~hours:0 ~mins:50 ~secs:0; tags = [
        { name = "DEV-101"; duration = Duration.of_hms ~hours:0 ~mins:33 ~secs:0 };
        { name = "DEV-202"; duration = Duration.of_hms ~hours:0 ~mins:12 ~secs:0 };
      ] };
    ];
    total = Duration.of_hms ~hours:2 ~mins:20 ~secs:0;
  } in
  run_styled (fun () -> display_watson_report report);
  [%expect {|
    (CTue 03 February 2026 -> Tue 03 February 2026/)

    (Rcoding/) - (G1h 30m/)

    (Rcr/) - (G50m/)
    [(UDEV-101 /) (G33m/)]
    [(UDEV-202 /) (G12m/)]

    (BTotal: (G2h 20m/)
    |}]

let%expect_test "display_watson_report: empty" =
  let report = {
    Watson.date_range = "Mon 03 February 2026 -> Mon 03 February 2026";
    entries = [];
    total = Duration.of_hms ~hours:0 ~mins:0 ~secs:0;
  } in
  run_styled (fun () -> display_watson_report report);
  [%expect {|
    (CMon 03 February 2026 -> Mon 03 February 2026/)

    (BTotal: (G0m/)
    |}]

let run_day ~config_path:_ ~config ~creds ~starred_projects ~date =
  (* Parse watson report *)
  let watson_cmd = sprintf "watson report -G -f %s -t %s" date date in
  let watson_output = Io.run_command watson_cmd in
  let report = match Watson.parse watson_output with
    | Ok report -> report
    | Error err -> failwith @@ sprintf "Could not parse Watson output: %s" @@ Error.to_string_hum err
  in
  display_watson_report report;

  let handle_split_tags cfg entry =
    let accept_tag acc cfg composite_key tag ticket =
      let description = Prompt.description ticket in
      let cfg = Config.set_mapping cfg composite_key (Config.Ticket ticket) in
      (Processor.Post {
        ticket; duration = Duration.round_5min tag.Watson.duration;
        source = sprintf "%s:%s" entry.Watson.project tag.Watson.name; description;
      } :: acc, cfg)
    in
    let handle_uncached_result acc cfg composite_key tag =
      match Prompt.uncached_tag ~creds ~starred_projects ~date
          ~project:entry.Watson.project tag with
      | Processor.Tag_accept ticket -> accept_tag acc cfg composite_key tag ticket
      | Processor.Tag_skip -> (acc, cfg)
    in
    let decisions, cfg = List.fold entry.Watson.tags ~init:([], cfg)
      ~f:(fun (acc, cfg) tag ->
        let composite_key = sprintf "%s:%s" entry.Watson.project tag.Watson.name in
        let tag_cached = Config.get_mapping cfg composite_key in
        let tag_cached = match tag_cached with
          | Some _ -> tag_cached
          | None when Ticket.is_ticket_pattern tag.name ->
            Some (Config.Ticket tag.name)
          | None -> None
        in
        match tag_cached with
        | Some (Config.Ticket ticket) ->
          let response, lookup_ok = Prompt.cached_tag ~creds tag ~ticket in
          (match response, lookup_ok with
           | (Prompt.Keep | Change_category), _ ->
             accept_tag acc cfg composite_key tag ticket
           | Change_ticket, false ->
             let cfg = { cfg with mappings =
               List.Assoc.remove cfg.mappings ~equal:String.equal composite_key } in
             handle_uncached_result acc cfg composite_key tag
           | Change_ticket, true ->
             handle_uncached_result acc cfg composite_key tag
           | Skip_once, _ -> (acc, cfg)
           | Split, _ -> (acc, cfg))
        | Some Config.Skip -> (acc, cfg)
        | None ->
          handle_uncached_result acc cfg composite_key tag)
    in
    (* Clear project-level mapping now that composite keys are set *)
    let cfg = { cfg with mappings =
      List.Assoc.remove cfg.mappings ~equal:String.equal entry.Watson.project } in
    (List.rev decisions, cfg, false)
  in

  let run_uncached cfg entry =
    match Prompt.uncached_entry ~creds ~starred_projects ~date entry with
    | Processor.Accept ticket ->
      let description = Prompt.description ticket in
      let cfg = Config.set_mapping cfg entry.Watson.project (Config.Ticket ticket) in
      ([Processor.Post {
        ticket; duration = Duration.round_5min entry.Watson.total;
        source = entry.Watson.project; description;
      }], cfg, false)
    | Processor.Skip_once -> ([], cfg, false)
    | Processor.Skip_always ->
      let cfg = Config.set_mapping cfg entry.Watson.project Config.Skip in
      ([Processor.Skip { project = entry.Watson.project; duration = entry.Watson.total }], cfg, false)
    | Processor.Split ->
      handle_split_tags cfg entry
  in

  let handle_cached_entry cfg entry ~ticket =
    let has_tags = not (List.is_empty entry.Watson.tags) in
    let response, lookup_ok = Prompt.cached_entry ~creds ~ticket ~has_tags in
    match response, lookup_ok with
    | Prompt.Keep, _ ->
      let description = Prompt.description ticket in
      let decisions = [Processor.Post {
        ticket; duration = Duration.round_5min entry.Watson.total;
        source = entry.Watson.project; description;
      }] in
      let cfg = Config.set_mapping cfg entry.Watson.project (Config.Ticket ticket) in
      (decisions, cfg, false)
    | Split, _ ->
      handle_split_tags cfg entry
    | Change_ticket, false ->
      let cfg = { cfg with mappings =
        List.Assoc.remove cfg.mappings ~equal:String.equal entry.project } in
      run_uncached cfg entry
    | Change_ticket, true -> run_uncached cfg entry
    | Change_category, _ ->
      let description = Prompt.description ticket in
      let decisions = [Processor.Post {
        ticket; duration = Duration.round_5min entry.Watson.total;
        source = entry.Watson.project; description;
      }] in
      let cfg = Config.set_mapping cfg entry.project (Config.Ticket ticket) in
      (decisions, cfg, true)
    | Skip_once, _ -> ([], cfg, false)
  in

  (* Process each entry *)
  let all_decisions, config =
    List.fold report.entries ~init:([], config) ~f:(fun (acc_decisions, cfg) entry ->
      let resolution = Processor.resolve_entry_mapping ~config:cfg
        ~project:entry.project ~tags:entry.tags in

      (* Always show entry context *)
      show_entry_context entry;

      (* Dispatch based on resolution *)
      let decisions, cfg, force_category_change = match resolution with
        | Processor.Project_cached ticket ->
          handle_cached_entry cfg entry ~ticket
        | Processor.Tag_inferred ticket ->
          handle_cached_entry cfg entry ~ticket
        | Processor.Auto_split ->
          Io.styled "  {info}auto-splitting{/}\n";
          handle_split_tags cfg entry
        | Processor.Project_skip ->
          let response = Prompt.cached_skip () in
          (match response with
           | Prompt.Change_ticket -> run_uncached cfg entry
           | Keep | Change_category | Skip_once | Split ->
             let decisions = [Processor.Skip {
               project = entry.project; duration = entry.total;
             }] in
             (decisions, cfg, false))
        | Processor.Uncached ->
          run_uncached cfg entry
      in

      (* Category prompting for each Post decision *)
      let cfg = match cfg.categories with
        | Some { options; _ } when not (String.is_empty cfg.tempo_category_attr_key)
            && not (List.is_empty options) ->
          List.fold decisions ~init:cfg ~f:(fun c -> function
            | Processor.Post { ticket; _ } ->
              if force_category_change then begin
                Io.output @@ sprintf "  %s category:\n" ticket;
                let value = Prompt.category_list ~options ~current_value:None in
                Config.set_category_selection c ticket value
              end else
                Prompt.category ~config:c ~options ticket
            | Processor.Skip _ -> c)
        | _ -> cfg
      in
      (List.rev_append decisions acc_decisions, cfg))
  in
  let all_decisions = List.rev all_decisions in

  (* Combined Summary *)
  Io.styled "\n{header}=== Summary ==={/}\n";
  let posts, skips = List.partition_tf all_decisions ~f:(function
    | Processor.Post _ -> true
    | Processor.Skip _ -> false) in

  let cat_options = match config.categories with
    | Some { options; _ } -> options | None -> [] in

  if not (List.is_empty posts) then begin
    Io.output "Post:\n";
    List.iter posts ~f:(function
      | Processor.Post { ticket; duration; source; description } ->
        let cat_str = match resolve_category_for_display ~config ~options:cat_options ticket with
          | Some cat -> sprintf "  {dim}[%s]{/}" (Category.name cat) | None -> "" in
        let desc_str = if String.is_empty description then ""
          else sprintf "  \"%s\"" description in
        Io.styled @@ sprintf "  {project}%-10s{/} ({duration}%s{/})  {action}%s{/}%s%s\n"
          source (Duration.to_string duration) ticket cat_str desc_str
      | Processor.Skip _ -> ())
  end;

  if not (List.is_empty skips) then begin
    Io.styled "{dim}Skip:{/}\n";
    List.iter skips ~f:(function
      | Processor.Skip { project; duration } ->
        Io.styled @@ sprintf "  {dim}%-10s (%s){/}\n" project (Duration.to_string duration)
      | Processor.Post _ -> ())
  end;

  if not (List.is_empty posts) then
    Io.styled @@ sprintf "{header}Total: {duration}%s{/}\n"
      (Duration.to_string @@ Processor.total_posted_duration posts);

  (* Confirmation prompt *)
  if not (List.is_empty posts) then begin
    Io.styled "\n{prompt}[Enter] post | [n] skip day:{/} ";
    let confirm = Io.input () in

    if not (String.equal confirm "n") then begin
      let date = parse_date_from_range report.date_range in
      Io.styled "\n{header}=== Posting ==={/}\n";

      (* Resolve issue IDs and post worklogs, accumulating config changes *)
      let results, config =
        List.fold posts ~init:([], config) ~f:(fun (acc, cfg) decision ->
          match decision with
          | Processor.Post { ticket; duration; source = _; description } ->
            (* Look up or fetch issue ID + account key *)
            let issue_id, account_key, cfg =
              match Config.get_issue_id cfg ticket, Config.get_account_key cfg ticket with
              | Some id, Some key -> (id, Some key, cfg)
              | _ ->
                Io.styled @@ sprintf "  {dim}Looking up %s...{/} " ticket;
                match Jira_api.fetch_issue_info ~creds ~ticket with
                | Ok (id, account_id) ->
                  let cfg = Config.set_issue_id cfg ticket id in
                  let account_key, cfg = match account_id with
                    | Some acct_id ->
                      (match Tempo_api.fetch_account_key ~token:cfg.tempo_token ~account_id:acct_id with
                       | Ok key ->
                         Io.styled @@ sprintf "{ok}OK{/} (id=%d, account=%s)\n" id key;
                         (Some key, Config.set_account_key cfg ticket key)
                       | Error msg ->
                         Io.styled @@ sprintf "{ok}OK{/} (id=%d)\n" id;
                         Io.styled @@ sprintf "  {warn}Warning: could not resolve account %s: %s{/}\n" acct_id msg;
                         (None, cfg))
                    | None ->
                      Io.styled @@ sprintf "{ok}OK{/} (id=%d)\n" id;
                      (None, cfg)
                  in
                  (id, account_key, cfg)
                | Error msg ->
                  Io.styled @@ sprintf "{err}FAILED: %s{/}\n" msg;
                  failwith @@ sprintf "Could not fetch issue info for %s" ticket
            in
            let cat_options = match cfg.categories with
              | Some { options; _ } -> options | None -> [] in
            let attributes =
              (match account_key with
               | Some key when not (String.is_empty cfg.tempo_account_attr_key) ->
                 [(cfg.tempo_account_attr_key, key)]
               | _ -> [])
              @ (match resolve_category_for_display ~config:cfg ~options:cat_options ticket with
                 | Some cat when not (String.is_empty cfg.tempo_category_attr_key) ->
                   [(cfg.tempo_category_attr_key, Category.value cat)]
                 | _ -> [])
            in
            let response =
              Tempo_api.post_worklog ~token:cfg.tempo_token
                ~issue_id ~author_account_id:cfg.jira_account_id
                ~duration ~date ~description ~attributes in
            let success = response.Io.status >= 200 && response.status < 300 in
            if success then
              Io.styled @@ sprintf "{ok}%s: OK{/}\n" ticket
            else begin
              Io.styled @@ sprintf "{err}%s: FAILED (%d){/}\n" ticket response.status;
              Io.styled @@ sprintf "  {dim}Response: %s{/}\n" response.body
            end;
            (success :: acc, cfg)
          | Processor.Skip _ -> (acc, cfg))
      in

      let ok_count = List.count results ~f:Fn.id in
      let total_count = List.length results in
      Io.styled @@ sprintf "\n{header}Posted %d/%d worklogs{/}\n" ok_count total_count;
      config
    end
    else config
  end
  else config

let run ~config_path ~dates =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  (* Credential prompts *)
  let config =
    if String.is_empty config.tempo_token then begin
      Io.output "Enter Tempo API token: ";
      let token = Io.input_secret () in
      { config with tempo_token = token }
    end
    else config
  in

  let config =
    if String.is_empty config.jira_base_url then begin
      Io.output "Enter Jira subdomain (e.g., 'company' for company.atlassian.net): ";
      let subdomain = Io.input () in
      let url = sprintf "https://%s.atlassian.net" subdomain in
      { config with jira_base_url = url }
    end
    else config
  in

  let config =
    if String.is_empty config.jira_email then begin
      Io.output "Enter Jira email: ";
      let email = Io.input () in
      { config with jira_email = email }
    end
    else config
  in

  let config =
    if String.is_empty config.jira_token then begin
      Io.output "Enter Jira API token (https://id.atlassian.com/manage-profile/security/api-tokens): ";
      let token = Io.input_secret () in
      { config with jira_token = token }
    end
    else config
  in

  (* Fetch Jira account ID if not cached *)
  let config =
    if String.is_empty config.jira_account_id then begin
      Io.output "Fetching Jira account ID... ";
      let jira_creds = { Jira_api.base_url = config.jira_base_url;
                         email = config.jira_email; token = config.jira_token } in
      match Jira_api.fetch_account_id ~creds:jira_creds with
      | Ok account_id ->
        Io.styled @@ sprintf "{ok}OK{/} (%s)\n" account_id;
        { config with jira_account_id = account_id }
      | Error msg ->
        Io.styled @@ sprintf "{err}FAILED: %s{/}\n" msg;
        failwith "Could not fetch Jira account ID"
    end
    else config
  in

  (* Save config after credential collection (before category prompt, so restore works) *)
  Config.save ~path:config_path config |> Or_error.ok_exn;

  (* Prompt for starred projects if not configured *)
  let config = if Option.is_none config.starred_projects then begin
    Io.output "No starred projects configured.\n";
    Io.output "Enter comma-separated Jira project keys to prioritise in search (e.g. DEV,ARCH): ";
    let input = Io.input () in
    let keys = String.split input ~on:',' |> List.map ~f:String.strip
      |> List.filter ~f:(fun s -> not (String.is_empty s)) in
    let valid_keys = List.filter keys ~f:Ticket.is_project_key in
    let invalid = List.filter keys ~f:(fun k -> not (Ticket.is_project_key k)) in
    if not (List.is_empty invalid) then
      Io.styled @@ sprintf "  {warn}Skipping invalid keys: %s{/}\n" (String.concat ~sep:", " invalid);
    if not (List.is_empty valid_keys) then
      Io.output @@ sprintf "Starred projects: %s\n" (String.concat ~sep:", " valid_keys);
    let config = { config with starred_projects = Some valid_keys } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    config
  end else config in

  (* Discover Tempo work attribute keys if not cached *)
  let config =
    if String.is_empty config.tempo_account_attr_key
       || String.is_empty config.tempo_category_attr_key then begin
      match Tempo_api.fetch_work_attribute_keys ~token:config.tempo_token with
      | Ok (account_key, category_key) ->
        let cfg = match account_key with
          | Some k when String.is_empty config.tempo_account_attr_key ->
            { config with tempo_account_attr_key = k }
          | _ -> config
        in
        (match category_key with
         | Some k when String.is_empty cfg.tempo_category_attr_key ->
           { cfg with tempo_category_attr_key = k }
         | _ -> cfg)
      | Error _ -> config
    end
    else config
  in

  (* Fetch categories if not cached *)
  let config =
    match config.categories with
    | Some _ -> config
    | None when not @@ String.is_empty config.tempo_category_attr_key -> (
      match Tempo_api.fetch_category_options ~token:config.tempo_token
          ~attr_key:config.tempo_category_attr_key with
       | Ok options ->
         { config with categories = Some {
             options;
             fetched_at = Date.to_string @@ Date.today ~zone:Time_float.Zone.utc;
           }
         }
       | Error msg ->
         Io.styled @@ sprintf "{warn}Warning: could not fetch categories: %s{/}\n" msg;
         config
    )
    | None -> config
  in

  (* Save config after category selection *)
  Config.save ~path:config_path config |> Or_error.ok_exn;

  (* Build Jira credentials *)
  let creds = { Jira_api.base_url = config.jira_base_url;
                email = config.jira_email; token = config.jira_token } in
  let starred_projects = Option.value ~default:[] config.starred_projects in

  (* Process each date *)
  let multi_day = List.length dates > 1 in
  let config =
    List.fold dates ~init:config ~f:(fun cfg date ->
      if multi_day then
        Io.styled @@ sprintf "\n{header}=== %s ==={/}\n" date;
      run_day ~config_path ~config:cfg ~creds ~starred_projects ~date)
  in

  (* Save final config *)
  Config.save ~path:config_path config |> Or_error.ok_exn
