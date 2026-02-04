open Core

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
  io.output @@ sprintf "Token configured: %s...\n" @@ String.prefix config.tempo_token 8;

  (* Parse watson report *)
  let watson_output = io.run_command "watson report -dG" in
  let report = Watson.parse watson_output |> Or_error.ok_exn in

  io.output @@ sprintf "Report: %s\n" report.date_range;
  io.output @@ sprintf "Entries: %d\n" @@ List.length report.entries;
  List.iter report.entries ~f:(fun entry ->
    io.output @@ sprintf "  %s - %s\n" entry.project @@ Duration.to_string entry.total);

  Config.save ~path:config_path config |> Or_error.ok_exn
