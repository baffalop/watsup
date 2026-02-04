open Core

type t = {
  input : unit -> string;
  output : string -> unit;
}

let stdio = {
  input = (fun () -> In_channel.(input_line_exn stdin));
  output = (fun s -> Out_channel.(output_string stdout s; flush stdout));
}

let create ~input ~output = { input; output }
