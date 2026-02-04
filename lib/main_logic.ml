open Core

let run ~io ~config_path =
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  let config =
    if String.is_empty config.tempo_token then begin
      io.Io.output "Enter Tempo API token: ";
      let token = io.input () in
      { config with tempo_token = token }
    end
    else config
  in

  io.output (sprintf "Token configured: %s...\n" (String.prefix config.tempo_token 8));
  Config.save ~path:config_path config |> Or_error.ok_exn;
  io.output (sprintf "Config saved to %s\n" config_path)
