module Config = Watsup.Config
module Io = Watsup.Io
module Main_logic = Watsup.Main_logic

let today () =
  let open Core in
  Date.to_string (Date.today ~zone:Time_float.Zone.utc)

let resolve_dates ~day ~from_date ~to_date =
  let open Core in
  match day, from_date, to_date with
  | None, None, None -> [today ()]
  | Some d, None, None ->
    (* -d DATE or -d -N for relative *)
    (match Int.of_string_opt d with
     | Some n when n < 0 ->
       let t = Date.add_days (Date.today ~zone:Time_float.Zone.utc) n in
       [Date.to_string t]
     | _ ->
       (* TODO: accept partial dates like "5" (day of current month) or "5-2" (Feb 5th) *)
       [d])
  | None, Some f, Some t ->
    let start = Date.of_string f in
    let stop = Date.of_string t in
    let rec range acc d =
      if Date.( > ) d stop then List.rev acc
      else range (Date.to_string d :: acc) (Date.add_days d 1)
    in
    range [] start
  | _ ->
    eprintf "Error: --day and --from/--to are mutually exclusive. --from requires --to.\n";
    Core.exit 1

let () =
  let open Climate.Arg_parser in
  let arg_parser =
    let+ day = named_opt ~doc:"Single day: ISO date or -N for relative" ["day"; "d"] string
    and+ from_date = named_opt ~doc:"Range start (ISO date)" ["from"; "f"] string
    and+ to_date = named_opt ~doc:"Range end (ISO date)" ["to"; "t"] string
    and+ star_projects = named_opt ~doc:"Comma-separated project keys to star" ["star-projects"] string
    in
    (day, from_date, to_date, star_projects)
  in
  let (day, from_date, to_date, star_projects) =
    Climate.Command.run_singleton ~doc:"Watson to Jira Tempo CLI" arg_parser
  in
  let config_path = Config.default_path () in
  match star_projects with
  | Some keys_str ->
    let open Core in
    let keys = String.split keys_str ~on:',' |> List.map ~f:String.strip
      |> List.filter ~f:(fun s -> not (String.is_empty s)) in
    let invalid = List.filter keys ~f:(fun k -> not (Ticket.is_project_key k)) in
    if not (List.is_empty invalid) then
      failwith (sprintf "Invalid project keys: %s" (String.concat ~sep:", " invalid));
    let config = Config.load ~path:config_path |> Or_error.ok_exn in
    let config = { config with starred_projects = Some keys } in
    Config.save ~path:config_path config |> Or_error.ok_exn;
    printf "Starred projects: %s\n" (String.concat ~sep:", " keys)
  | None ->
    let dates = resolve_dates ~day ~from_date ~to_date in
    Io.with_stdio (fun () -> Main_logic.run ~config_path ~dates)
