open Core
module Config = Watsup.Config

let main ~input ~output =
  let config_path = Config.default_path () in
  let config = Config.load ~path:config_path |> Or_error.ok_exn in

  let config =
    if String.is_empty config.tempo_token then begin
      output "Enter Tempo API token: ";
      let token = input () in
      { config with tempo_token = token }
    end
    else config
  in

  output (sprintf "Token: %s\n" (String.prefix config.tempo_token 8 ^ "..."));
  Config.save ~path:config_path config |> Or_error.ok_exn;
  output (sprintf "Config saved to %s\n" config_path)

let () =
  let input () = In_channel.(input_line_exn stdin) in
  let output s = Out_channel.(output_string stdout s; flush stdout) in
  main ~input ~output
