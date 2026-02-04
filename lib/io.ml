open Core

type http_response = {
  status : int;
  body : string;
}

type t = {
  input : unit -> string;
  output : string -> unit;
  run_command : string -> string;
  http_post : url:string -> headers:(string * string) list -> body:string -> http_response Lwt.t;
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
  http_post = real_http_post;
}

let create ~input ~output ~run_command ~http_post = { input; output; run_command; http_post }
