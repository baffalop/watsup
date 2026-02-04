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

  (* Process each entry *)
  let all_decisions = ref [] in
  let config = ref config in

  List.iter report.entries ~f:(fun entry ->
    let cached = Config.get_mapping !config entry.project in
    let decisions, new_mapping = Processor.process_entry
      ~entry ~cached
      ~prompt:(prompt_for_entry ~io) in
    all_decisions := !all_decisions @ decisions;
    Option.iter new_mapping ~f:(fun m ->
      config := Config.set_mapping !config entry.project m));

  (* Summary *)
  io.output "\n=== Summary ===\n";
  let posts, skips = List.partition_tf !all_decisions ~f:(function
    | Processor.Post _ -> true
    | Processor.Skip _ -> false) in

  List.iter posts ~f:(function
    | Processor.Post { ticket; duration; source } ->
      io.output @@ sprintf "POST: %s (%s) from %s\n" ticket (Duration.to_string duration) source
    | _ -> ());

  List.iter skips ~f:(function
    | Processor.Skip { project; duration } ->
      io.output @@ sprintf "SKIP: %s (%s)\n" project (Duration.to_string duration)
    | _ -> ());

  Config.save ~path:config_path !config |> Or_error.ok_exn
