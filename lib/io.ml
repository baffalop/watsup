open Core

type t = {
  input : unit -> string;
  output : string -> unit;
  run_command : string -> string;
}

let stdio = {
  input = (fun () -> In_channel.(input_line_exn stdin));
  output = (fun s -> Out_channel.(output_string stdout s; flush stdout));
  run_command = (fun cmd ->
    let ic = Core_unix.open_process_in cmd in
    let output = In_channel.input_all ic in
    match Core_unix.close_process_in ic with
    | Ok () -> output
    | Error err ->
      failwith @@ sprintf "Command failed: %s (%s)" cmd
        (Core_unix.Exit_or_signal.to_string_hum (Error err)));
}

let create ~input ~output ~run_command = { input; output; run_command }
