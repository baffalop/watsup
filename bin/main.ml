open Core
module Config = Watsup.Config
module Duration = Watsup.Duration
module Prompt = Watsup.Prompt
module Ticket = Watsup.Ticket
module Watson = Watsup.Watson
module Tempo = Watsup.Tempo
module Worklog = Watsup.Worklog

let run_watson () =
  let ic = Core_unix.open_process_in "watson report -dG" in
  let output = In_channel.input_all ic in
  let _ = Core_unix.close_process_in ic in
  output

let process_entries config entries =
  let worklogs = ref [] in
  let skipped = ref [] in
  let category =
    ref
      (match config.Config.category with
       | Some c -> c.selected
       | None -> "Development")
  in
  let config = ref config in

  let rec process_entry entry =
    let cached = Config.get_mapping !config entry.Watson.project in
    match cached with
    | Some Config.Skip ->
      skipped := (entry.project, entry.total) :: !skipped
    | Some Config.Auto_extract ->
      let tickets =
        Ticket.extract_tickets
          (List.map entry.tags ~f:(fun t -> t.Watson.name))
      in
      List.iter tickets ~f:(fun ticket ->
          let tag =
            List.find_exn entry.tags ~f:(fun t -> String.equal t.name ticket)
          in
          worklogs :=
            {
              Worklog.ticket;
              duration = Duration.round_5min tag.duration;
              date = Date.today ~zone:Time_float.Zone.utc;
              category = !category;
              account = None;
              message = None;
              source = sprintf "%s:%s" entry.project ticket;
            }
            :: !worklogs)
    | _ ->
      let action = Prompt.prompt_entry entry ~cached ~category:!category in
      (match action with
       | Prompt.Accept ticket ->
         config :=
           Config.set_mapping !config entry.project (Config.Ticket ticket);
         worklogs :=
           {
             Worklog.ticket;
             duration = Duration.round_5min entry.total;
             date = Date.today ~zone:Time_float.Zone.utc;
             category = !category;
             account = None;
             message = None;
             source = entry.project;
           }
           :: !worklogs
       | Prompt.Skip -> ()
       | Prompt.Skip_always ->
         config := Config.set_mapping !config entry.project Config.Skip;
         skipped := (entry.project, entry.total) :: !skipped
       | Prompt.Split ->
         List.iter entry.tags ~f:(fun tag ->
             let action = Prompt.prompt_tag ~project:entry.project tag in
             match action with
             | Prompt.Accept ticket ->
               worklogs :=
                 {
                   Worklog.ticket;
                   duration = Duration.round_5min tag.duration;
                   date = Date.today ~zone:Time_float.Zone.utc;
                   category = !category;
                   account = None;
                   message = None;
                   source = sprintf "%s:%s" entry.project tag.name;
                 }
                 :: !worklogs
             | _ -> ())
       | Prompt.Change_category -> process_entry entry
       | Prompt.Set_message _ -> process_entry entry
       | Prompt.Quit -> raise_s [%message "User quit"])
  in

  List.iter entries ~f:process_entry;
  (List.rev !worklogs, List.rev !skipped, !config)

let main () =
  let config_path = Config.default_path () in
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  let config =
    if String.is_empty config.tempo_token then
      let token = Prompt.prompt_token () in
      { config with tempo_token = token }
    else config
  in

  let watson_output = run_watson () in
  let report = Watson.parse watson_output |> Or_error.ok_exn in

  printf "Watson report: %s\n" report.date_range;
  printf "Total entries: %d\n" (List.length report.entries);

  let worklogs, skipped, config = process_entries config report.entries in

  if List.is_empty worklogs then printf "\nNo worklogs to post.\n"
  else begin
    let manual = [] in
    if Prompt.prompt_confirm_post worklogs ~skipped ~manual then begin
      printf "\nPosting worklogs...\n";
      Lwt_main.run
        (let open Lwt.Syntax in
         let* results =
           Lwt_list.map_s
             (fun w ->
               let* result = Tempo.post_worklog ~token:config.tempo_token w in
               let status =
                 match result with
                 | Worklog.Posted -> "done"
                 | Worklog.Failed msg -> sprintf "FAILED: %s" msg
                 | Worklog.Manual_required msg -> sprintf "MANUAL: %s" msg
               in
               printf "  %s (%s) - %s\n%!" w.Worklog.ticket
                 (Duration.to_string w.duration)
                 status;
               Lwt.return result)
             worklogs
         in
         let posted =
           List.count results ~f:(function
             | Worklog.Posted -> true
             | _ -> false)
         in
         let failed =
           List.count results ~f:(function
             | Worklog.Failed _ -> true
             | _ -> false)
         in
         printf "\nSummary: %d posted, %d failed\n" posted failed;
         Lwt.return ())
    end
    else printf "\nAborted.\n"
  end;

  Config.save ~path:config_path config |> Or_error.ok_exn;
  printf "\nConfig saved to %s\n" config_path

let () = main ()
