open Core

type http_response = {
  status : int;
  body : string;
}

type _ Effect.t +=
  | Input : string Effect.t
  | Input_secret : string Effect.t
  | Output : string -> unit Effect.t
  | Run_command : string -> string Effect.t
  | Http_post : { url: string; headers: (string * string) list; body: string }
      -> http_response Effect.t
  | Http_get : { url: string; headers: (string * string) list }
      -> http_response Effect.t

let input () = Effect.perform Input
let input_secret () = Effect.perform Input_secret
let output s = Effect.perform (Output s)
let run_command cmd = Effect.perform (Run_command cmd)
let http_post ~url ~headers ~body = Effect.perform (Http_post { url; headers; body })
let http_get ~url ~headers = Effect.perform (Http_get { url; headers })

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
  (* Disable terminal echo for password input, falling back to plain read if not a TTY *)
  let fd = Core_unix.File_descr.of_int 0 in
  match Core_unix.Terminal_io.tcgetattr fd with
  | termios ->
    let original_echo = termios.c_echo in
    termios.c_echo <- false;
    Core_unix.Terminal_io.tcsetattr termios fd ~mode:TCSANOW;
    let result = In_channel.(input_line_exn stdin) in
    termios.c_echo <- original_echo;
    Core_unix.Terminal_io.tcsetattr termios fd ~mode:TCSANOW;
    Out_channel.(output_string stdout "\n"; flush stdout);
    result
  | exception Core_unix.Unix_error _ ->
    In_channel.(input_line_exn stdin)

let run_command_impl cmd =
  let ic = Core_unix.open_process_in cmd in
  let output = In_channel.input_all ic in
  match Core_unix.close_process_in ic with
  | Ok () -> output
  | Error err ->
    failwith @@ sprintf "Command failed: %s (%s)" cmd
      @@ Core_unix.Exit_or_signal.to_string_hum @@ Error err

let with_stdio f =
  let open Effect.Deep in
  try f () with
  | effect Input, k -> continue k In_channel.(input_line_exn stdin)
  | effect Input_secret, k -> continue k @@ read_secret ()
  | effect (Output s), k ->
    Out_channel.(output_string stdout s; flush stdout);
    continue k ()
  | effect (Run_command cmd), k ->
    continue k @@ run_command_impl cmd
  | effect (Http_post { url; headers; body }), k ->
    continue k @@ Lwt_main.run @@ real_http_post ~url ~headers ~body
  | effect (Http_get { url; headers }), k ->
    continue k @@ Lwt_main.run @@ real_http_get ~url ~headers
