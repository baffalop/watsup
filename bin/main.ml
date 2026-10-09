module Config = Watsup.Config
module Date_arg = Watsup.Date_arg
module Io = Watsup.Io
module Jira_api = Watsup.Jira_api
module Jira_search = Watsup.Jira_search
module Main_logic = Watsup.Main_logic
module Ticket = Watsup.Ticket

let today () =
  let open Core in
  Date.to_string (Date.today ~zone:Time_float.Zone.utc)

let resolve_dates ~day ~from_date ~to_date =
  let open Core in
  let today = Date.today ~zone:Time_float.Zone.utc in
  match Date_arg.resolve ~today ~day ~from_date ~to_date with
  | Ok dates -> List.map dates ~f:Date.to_string
  | Error e ->
    eprintf "Error: %s\n" (Error.to_string_hum e);
    Core.exit 1

let () =
  let open Climate.Arg_parser in
  let date_formats = "YYYY-MM-DD, MM-DD, DD, 0 (today) or -N (N days ago)" in
  let arg_parser =
    let+ day = named_opt ~doc:("Single day: " ^ date_formats) ["day"; "d"] string
    and+ from_date = named_opt ~doc:("Range start: " ^ date_formats) ["from"; "f"] string
    and+ to_date = named_opt ~doc:"Range end (default: today), same formats as --from" ["to"; "t"] string
    and+ star_projects = named_opt ~doc:"Add comma-separated project keys to starred list" ["star-projects"] string
    and+ search_mode = named_opt ~doc:"Test search prompt in isolation" ["search"] string
    in
    (day, from_date, to_date, star_projects, search_mode)
  in
  let (day, from_date, to_date, star_projects, search_mode) =
    Climate.Command.run_singleton ~doc:"Watson to Jira Tempo CLI" arg_parser
  in
  let config_path = Config.default_path () in
  match star_projects, search_mode with
  | Some keys_str, _ ->
    let open Core in
    let keys = String.split keys_str ~on:',' |> List.map ~f:String.strip
      |> List.filter ~f:(fun s -> not (String.is_empty s)) in
    let invalid = List.filter keys ~f:(fun k -> not (Ticket.is_project_key k)) in
    if not (List.is_empty invalid) then
      failwith (sprintf "Invalid project keys: %s" (String.concat ~sep:", " invalid));
    let config = Config.load ~path:config_path |> Or_error.ok_exn in
    let existing = Option.value ~default:[] config.starred_projects in
    let merged = List.dedup_and_sort ~compare:String.compare (existing @ keys) in
    let config = { config with starred_projects = Some merged } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    printf "Starred projects: %s\n" (String.concat ~sep:", " merged)
  | _, Some search_terms ->
    let open Core in
    let config = Config.load ~path:config_path |> Or_error.ok_exn in
    if String.is_empty config.jira_base_url
       || String.is_empty config.jira_email
       || String.is_empty config.jira_token then
      failwith "Jira credentials not configured. Run watsup once first to set them up.";
    let creds = Jira_api.make_creds ~base_url:config.jira_base_url
                  ~email:config.jira_email ~token:config.jira_token in
    let starred_projects = Option.value ~default:[] config.starred_projects in
    let log_date = today () in
    Io.with_stdio (fun () ->
      let outcome = Jira_search.prompt_loop ~creds ~search_hint:search_terms
        ~has_tags:false ~starred_projects ~log_date in
      match outcome with
      | Jira_search.Selected r ->
        printf "Selected: %s (%d) - %s\n" (Ticket.Key.to_string r.key) r.id r.summary
      | Jira_search.Skip_once -> printf "Skipped\n"
      | Jira_search.Skip_always -> printf "Skip always\n"
      | Jira_search.Split -> printf "Split\n")
  | None, None ->
    let dates = resolve_dates ~day ~from_date ~to_date in
    Io.with_stdio (fun () -> Main_logic.run ~config_path ~dates)
