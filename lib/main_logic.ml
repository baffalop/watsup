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

  Config.save ~path:config_path config |> Or_error.ok_exn
