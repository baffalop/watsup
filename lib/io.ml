open Core

type http_response = {
  status : int;
  body : string;
}

type t = {
  input : unit -> string;
  input_secret : unit -> string;
  output : string -> unit;
  run_command : string -> string;
  http_post : url:string -> headers:(string * string) list -> body:string -> http_response Lwt.t;
  http_get : url:string -> headers:(string * string) list -> http_response Lwt.t;
}

let real_http_post ~url ~headers ~body =
  let open Lwt.Syntax in
  let uri = Uri.of_string url in
  let headers = Cohttp.Header.of_list headers in
  let body = Cohttp_lwt.Body.of_string body in
  let* resp, resp_body = Cohttp_lwt_unix.Client.post ~headers ~body uri in
  let* body_str = Cohttp_lwt.Body.to_string resp_body in
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  Lwt.return { status; body = body_str }

let real_http_get ~url ~headers =
  let open Lwt.Syntax in
  let uri = Uri.of_string url in
  let headers = Cohttp.Header.of_list headers in
  let* resp, resp_body = Cohttp_lwt_unix.Client.get ~headers uri in
  let* body_str = Cohttp_lwt.Body.to_string resp_body in
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  Lwt.return { status; body = body_str }

let read_secret () =
  (* Disable terminal echo for password input *)
  let fd = Core_unix.File_descr.of_int 0 in  (* stdin = fd 0 *)
  let termios = Core_unix.Terminal_io.tcgetattr fd in
  let original_echo = termios.c_echo in
  termios.c_echo <- false;
  Core_unix.Terminal_io.tcsetattr termios fd ~mode:TCSANOW;
  let result = In_channel.(input_line_exn stdin) in
  termios.c_echo <- original_echo;
  Core_unix.Terminal_io.tcsetattr termios fd ~mode:TCSANOW;
  Out_channel.(output_string stdout "\n"; flush stdout);
  result

let stdio = {
  input = (fun () -> In_channel.(input_line_exn stdin));
  input_secret = read_secret;
  output = (fun s -> Out_channel.(output_string stdout s; flush stdout));
  run_command = (fun cmd ->
    let ic = Core_unix.open_process_in cmd in
    let output = In_channel.input_all ic in
    match Core_unix.close_process_in ic with
    | Ok () -> output
    | Error err ->
      failwith @@ sprintf "Command failed: %s (%s)" cmd
        (Core_unix.Exit_or_signal.to_string_hum (Error err)));
  http_post = real_http_post;
  http_get = real_http_get;
}

let create ~input ~input_secret ~output ~run_command ~http_post ~http_get =
  { input; input_secret; output; run_command; http_post; http_get }
