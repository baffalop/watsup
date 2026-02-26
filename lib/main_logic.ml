open Core

(* Jira API helpers *)
let jira_auth_header ~email ~token =
  let encoded = Base64.encode_exn (sprintf "%s:%s" email token) in
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
    Error (sprintf "Jira API error (%d) at %s: %s" response.status url response.body)

(* Fetch issue ID and Tempo account key from Jira in one call.
   Uses ?expand=names to discover the "Account" custom field. *)
let fetch_jira_issue_info ~io ~config ~ticket =
  let url = sprintf "%s/rest/api/2/issue/%s?expand=names" config.Config.jira_base_url ticket in
  let headers = [
    jira_auth_header ~email:config.jira_email ~token:config.jira_token;
    ("Accept", "application/json");
  ] in
  let response = Lwt_main.run @@ io.Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    let json = Yojson.Safe.from_string response.body in
    let issue_id = match Yojson.Safe.Util.member "id" json with
      | `String id_str -> Int.of_string id_str
      | _ -> failwith "id not found in Jira response"
    in
    let account_key =
      let names = Yojson.Safe.Util.(json |> member "names") in
      let fields = Yojson.Safe.Util.(json |> member "fields") in
      match names with
      | `Assoc name_list ->
        let account_field_id = List.find_map name_list ~f:(fun (field_id, name) ->
          match name with
          | `String n when String.is_substring (String.lowercase n) ~substring:"account" -> Some field_id
          | _ -> None
        ) in
        (match account_field_id with
         | Some field_id ->
           let field_value = Yojson.Safe.Util.member field_id fields in
           (match field_value with
            | `Null -> None
            | `Assoc _ ->
              (* Jira stores Tempo account as {"id": <int>, "value": <name>} *)
              (match Yojson.Safe.Util.member "id" field_value with
               | `Int id -> Some (Int.to_string id)
               | _ -> None)
            | _ -> None)
         | None -> None)
      | _ -> None
    in
    Ok (issue_id, account_key)
  else
    Error (sprintf "Jira API error (%d): %s" response.status response.body)

(* Discover work attribute keys from Tempo (Account and Category) *)
let fetch_work_attribute_keys ~io ~token =
  let url = "https://api.tempo.io/4/work-attributes" in
  let headers = [
    ("Authorization", sprintf "Bearer %s" token);
    ("Accept", "application/json");
  ] in
  let response = Lwt_main.run @@ io.Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    let json = Yojson.Safe.from_string response.body in
    match Yojson.Safe.Util.(json |> member "results") with
    | `List attrs ->
      let find_key ~substring =
        List.find_map attrs ~f:(fun attr ->
          let name = Yojson.Safe.Util.(attr |> member "name" |> to_string) in
          let key = Yojson.Safe.Util.(attr |> member "key" |> to_string) in
          if String.is_substring (String.lowercase name) ~substring
          then Some key else None)
      in
      Ok (find_key ~substring:"account", find_key ~substring:"category")
    | _ -> Error "Unexpected work-attributes response format"
  else
    Error (sprintf "Tempo work-attributes error (%d): %s" response.status response.body)

(* Fetch category options for a STATIC_LIST work attribute.
   Returns list of (value, display_name) pairs. *)
let fetch_category_options ~io ~token ~attr_key
  : (Category.t list, string) Result.t =
  let url = sprintf "https://api.tempo.io/4/work-attributes/%s" attr_key in
  let headers = [
    ("Authorization", sprintf "Bearer %s" token);
    ("Accept", "application/json");
  ] in
  let response = Lwt_main.run @@ io.Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    let json = Yojson.Safe.from_string response.body in
    let names_map = match Yojson.Safe.Util.(json |> member "names") with
      | `Assoc pairs ->
        List.filter_map pairs ~f:(fun (k, v) ->
          match v with `String s -> Some (k, s) | _ -> None)
      | _ -> []
    in
    let values = match Yojson.Safe.Util.(json |> member "values") with
      | `List vs ->
        List.filter_map vs ~f:(fun v ->
          match v with
          | `String key ->
            let name = List.Assoc.find names_map ~equal:String.equal key
              |> Option.value ~default:key in
            Some (key, name)
          | _ -> None)
      | _ -> []
    in
    if List.is_empty values then Error "No Tempo category values found"
    else values
    |> List.map ~f:(fun (value, name) -> Category.make ~value ~name)
    |> Result.return
  else
    Result.fail @@ sprintf "Tempo work-attribute lookup error (%d): %s"
      response.status response.body

(* Look up Tempo account key by numeric ID *)
let fetch_tempo_account_key ~io ~token ~account_id =
  let url = sprintf "https://api.tempo.io/4/accounts/%s" account_id in
  let headers = [
    ("Authorization", sprintf "Bearer %s" token);
    ("Accept", "application/json");
  ] in
  let response = Lwt_main.run @@ io.Io.http_get ~url ~headers in
  if response.status >= 200 && response.status < 300 then
    let json = Yojson.Safe.from_string response.body in
    match Yojson.Safe.Util.member "key" json with
    | `String key -> Ok key
    | _ -> Error "key not found in Tempo account response"
  else
    Error (sprintf "Tempo account lookup error (%d): %s" response.status response.body)

let prompt_for_entry ~io entry =
  io.Io.output @@ sprintf "\n%s - %s\n"
    entry.Watson.project
    (Duration.to_string @@ Duration.round_5min entry.total);
  let has_tags = not (List.is_empty entry.tags) in
  if has_tags then
    List.iter entry.tags ~f:(fun tag ->
      io.output @@ sprintf "  [%-8s %s]\n" tag.Watson.name
        (Duration.to_string @@ Duration.round_5min tag.duration));
  let prompt_str = if has_tags
    then "  [ticket] assign all | [s] split by tags | [n] skip | [S] skip always: "
    else "  [ticket] assign | [n] skip | [S] skip always: "
  in
  io.output prompt_str;
  let input = io.input () in
  match input with
  | "n" -> Processor.Skip_once
  | "S" -> Processor.Skip_always
  | "s" when has_tags -> Processor.Split
  | ticket -> Processor.Accept ticket

let prompt_for_tag ~io ~project:_ tag =
  io.Io.output @@ sprintf "  [%-8s %s] [ticket] assign | [n] skip: "
    tag.Watson.name
    (Duration.to_string @@ Duration.round_5min tag.Watson.duration);
  let input = io.input () in
  match input with
  | "n" -> Processor.Tag_skip
  | "" when Ticket.is_ticket_pattern tag.name -> Processor.Tag_accept tag.name
  | ticket -> Processor.Tag_accept ticket

let prompt_description ~io ticket =
  io.Io.output @@ sprintf "  Description for %s (optional): " ticket;
  io.input ()

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

let build_worklog_json ~issue_id ~author_account_id ~duration_seconds ~date ~description ~attributes =
  let open Yojson.Safe in
  let base = [
    ("issueId", `Int issue_id);
    ("authorAccountId", `String author_account_id);
    ("timeSpentSeconds", `Int duration_seconds);
    ("startDate", `String date);
    ("startTime", `String "09:00:00");
    ("description", `String description);
  ] in
  let fields = match attributes with
    | [] -> base
    | attrs ->
      base @ [("attributes", `List (
        List.map attrs ~f:(fun (key, value) ->
          `Assoc [("key", `String key); ("value", `String value)])
      ))]
  in
  to_string (`Assoc fields)

let post_worklog ~io ~token ~issue_id ~author_account_id ~duration ~date ~description ~attributes =
  let url = "https://api.tempo.io/4/worklogs" in
  let headers = [
    ("Authorization", sprintf "Bearer %s" token);
    ("Content-Type", "application/json");
  ] in
  let duration_seconds = Duration.to_seconds duration in
  let body = build_worklog_json ~issue_id ~author_account_id ~duration_seconds ~date ~description ~attributes in
  io.Io.http_post ~url ~headers ~body

let prompt_category_list ~io ~options ~current_value =
  List.iteri options ~f:(fun i cat ->
    let marker = match current_value with
      | Some v when String.equal v (Category.value cat) -> " *"
      | _ -> ""
    in
    io.Io.output @@ sprintf "    %d. %s%s\n" (i + 1) (Category.name cat) marker);
  io.output "  > ";
  let input = io.input () in
  match Int.of_string_opt input with
  | Some n when n >= 1 && n <= List.length options ->
    Category.value (List.nth_exn options (n - 1))
  | _ ->
    (* Default to first option on invalid input *)
    Category.value (List.hd_exn options)

let prompt_category ~io ~config ~options ticket =
  match Config.get_category_selection config ticket with
  | Some cached_value ->
    (* Check if cached value still resolves *)
    (match List.find options ~f:(fun cat -> String.equal (Category.value cat) cached_value) with
     | Some cat ->
       io.Io.output @@ sprintf "  %s category: %s\n    [Enter] keep | [c] change: " ticket (Category.name cat);
       let input = io.input () in
       if String.equal input "c" then begin
         let value = prompt_category_list ~io ~options ~current_value:(Some cached_value) in
         Config.set_category_selection config ticket value
       end else
         config
     | None ->
       (* Stale value - warn and prompt fresh *)
       io.Io.output @@ sprintf "  %s category (previous selection no longer available):\n" ticket;
       let value = prompt_category_list ~io ~options ~current_value:None in
       Config.set_category_selection config ticket value)
  | None ->
    io.Io.output @@ sprintf "  %s category:\n" ticket;
    let value = prompt_category_list ~io ~options ~current_value:None in
    Config.set_category_selection config ticket value

let resolve_category_for_display ~config ~options ticket =
  match Config.get_category_selection config ticket with
  | Some value ->
    List.find options ~f:(fun cat -> String.equal (Category.value cat) value)
  | None -> None

let run_day ~io ~config_path:_ ~config ~date =
  (* Parse watson report *)
  let watson_cmd = sprintf "watson report -G -f %s -t %s" date date in
  let watson_output = io.Io.run_command watson_cmd in
  let report = Watson.parse watson_output |> Or_error.ok_exn in

  io.output @@ sprintf "Report: %s (%d entries)\n"
    report.date_range (List.length report.entries);

  (* Process each entry - using fold for O(n) instead of O(n²) append *)
  let all_decisions, config =
    List.fold report.entries ~init:([], config) ~f:(fun (acc_decisions, cfg) entry ->
      let cached = Config.get_mapping cfg entry.project in
      let decisions, new_mapping = Processor.process_entry
        ~entry ~cached
        ~prompt:(prompt_for_entry ~io)
        ~tag_prompt:(prompt_for_tag ~io ~project:entry.project)
        ~describe:(prompt_description ~io)
        () in
      let cfg' = Option.value_map new_mapping ~default:cfg
        ~f:(fun m -> Config.set_mapping cfg entry.project m) in
      (* Category prompting for each Post decision *)
      let cfg' = match cfg'.categories with
        | Some { options; _ } when not (String.is_empty cfg'.tempo_category_attr_key)
            && not (List.is_empty options) ->
          List.fold decisions ~init:cfg' ~f:(fun c -> function
            | Processor.Post { ticket; _ } -> prompt_category ~io ~config:c ~options ticket
            | Processor.Skip _ -> c)
        | _ -> cfg'
      in
      (List.rev_append decisions acc_decisions, cfg'))
  in
  let all_decisions = List.rev all_decisions in

  (* Summary *)
  io.output "\n=== Summary ===\n";
  let posts, skips = List.partition_tf all_decisions ~f:(function
    | Processor.Post _ -> true
    | Processor.Skip _ -> false) in

  let cat_options = match config.categories with
    | Some { options; _ } -> options | None -> [] in
  List.iter posts ~f:(function
    | Processor.Post { ticket; duration; source; _ } ->
      let cat_str = match resolve_category_for_display ~config ~options:cat_options ticket with
        | Some cat -> sprintf " [%s]" (Category.name cat) | None -> "" in
      io.output @@ sprintf "POST: %s (%s)%s from %s\n" ticket (Duration.to_string duration) cat_str source
    | Processor.Skip _ -> ());

  List.iter skips ~f:(function
    | Processor.Skip { project; duration } ->
      io.output @@ sprintf "SKIP: %s (%s)\n" project (Duration.to_string duration)
    | Processor.Post _ -> ());

  (* If there are posts, ask for confirmation and post to Tempo *)
  if not (List.is_empty posts) then begin
    io.output "\n=== Worklogs to Post ===\n";
    List.iter posts ~f:(function
      | Processor.Post { ticket; duration; source = _; description } ->
        let desc_suffix = if String.is_empty description then ""
          else sprintf " - %s" description in
        io.output @@ sprintf "  %s: %s%s\n" ticket (Duration.to_string duration) desc_suffix
      | Processor.Skip _ -> ());

    io.output "[Enter] post | [n] skip day: ";
    let confirm = io.input () in

    if not (String.equal confirm "n") then begin
      let date = parse_date_from_range report.date_range in
      io.output "\n=== Posting ===\n";

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
                io.output @@ sprintf "  Looking up %s... " ticket;
                match fetch_jira_issue_info ~io ~config:cfg ~ticket with
                | Ok (id, account_id) ->
                  let cfg = Config.set_issue_id cfg ticket id in
                  (* Resolve account ID to Tempo account key *)
                  let account_key, cfg = match account_id with
                    | Some acct_id ->
                      (match fetch_tempo_account_key ~io ~token:cfg.tempo_token ~account_id:acct_id with
                       | Ok key ->
                         io.output @@ sprintf "OK (id=%d, account=%s)\n" id key;
                         (Some key, Config.set_account_key cfg ticket key)
                       | Error msg ->
                         io.output @@ sprintf "OK (id=%d)\n" id;
                         io.output @@ sprintf "  Warning: could not resolve account %s: %s\n" acct_id msg;
                         (None, cfg))
                    | None ->
                      io.output @@ sprintf "OK (id=%d)\n" id;
                      (None, cfg)
                  in
                  (id, account_key, cfg)
                | Error msg ->
                  io.output @@ sprintf "FAILED: %s\n" msg;
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
            let response = Lwt_main.run @@
              post_worklog ~io ~token:cfg.tempo_token
                ~issue_id ~author_account_id:cfg.jira_account_id
                ~duration ~date ~description ~attributes in
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
      config
    end
    else config
  end
  else config

let run ~io ~config_path ~dates =
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
      io.Io.output "Enter Jira subdomain (e.g., 'company' for company.atlassian.net): ";
      let subdomain = io.input () in
      let url = sprintf "https://%s.atlassian.net" subdomain in
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
      io.Io.output "Enter Jira API token (https://id.atlassian.com/manage-profile/security/api-tokens): ";
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

  (* Save config after credential collection (before category prompt, so restore works) *)
  Config.save ~path:config_path config |> Or_error.ok_exn;

  (* Discover Tempo work attribute keys if not cached *)
  let config =
    if String.is_empty config.tempo_account_attr_key
       || String.is_empty config.tempo_category_attr_key then begin
      match fetch_work_attribute_keys ~io ~token:config.tempo_token with
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
      match fetch_category_options ~io ~token:config.tempo_token
          ~attr_key:config.tempo_category_attr_key with
       | Ok options ->
         { config with categories = Some {
             options;
             fetched_at = Date.to_string @@ Date.today ~zone:Time_float.Zone.utc;
           }
         }
       | Error msg ->
         io.Io.output @@ sprintf "Warning: could not fetch categories: %s\n" msg;
         config
    )
    | None -> config
  in

  (* Save config after category selection *)
  Config.save ~path:config_path config |> Or_error.ok_exn;

  (* Process each date *)
  let multi_day = List.length dates > 1 in
  let config =
    List.fold dates ~init:config ~f:(fun cfg date ->
      if multi_day then
        io.output @@ sprintf "\n=== %s ===\n" date;
      run_day ~io ~config_path ~config:cfg ~date)
  in

  (* Save final config *)
  Config.save ~path:config_path config |> Or_error.ok_exn
