open Core

type http_response = {
  status : int;
  body : string;
}

type color = Reset | Bold | Dim | Red | Green | Yellow | Blue | Cyan

type _ Effect.t +=
  | Input : string Effect.t
  | Input_secret : string Effect.t
  | Output : string -> unit Effect.t
  | Set_color : color -> unit Effect.t
  | Run_command : string -> string Effect.t
  | Http_post : { url: string; headers: (string * string) list; body: string }
      -> http_response Effect.t
  | Http_get : { url: string; headers: (string * string) list }
      -> http_response Effect.t

let input () = Effect.perform Input
let input_secret () = Effect.perform Input_secret
let output s = Effect.perform (Output s)
let set_color c = Effect.perform (Set_color c)
let run_command cmd = Effect.perform (Run_command cmd)
let http_post ~url ~headers ~body = Effect.perform (Http_post { url; headers; body })
let http_get ~url ~headers = Effect.perform (Http_get { url; headers })

let ansi_code_of_color = function
  | Reset -> "\027[0m"
  | Bold -> "\027[1m"
  | Dim -> "\027[2m"
  | Red -> "\027[31m"
  | Green -> "\027[32m"
  | Yellow -> "\027[33m"
  | Blue -> "\027[34m"
  | Cyan -> "\027[36m"

let color_of_tag = function
  | "header" -> Some Bold
  | "ok" -> Some Green
  | "err" -> Some Red
  | "warn" -> Some Yellow
  | "info" -> Some Cyan
  | "dim" -> Some Dim
  | "action" -> Some Blue
  | "prompt" -> Some Dim
  | "project" -> Some Red
  | "duration" -> Some Green
  | "tag" -> Some Blue
  | "/" -> Some Reset
  | _ -> None

let styled s =
  let len = String.length s in
  let buf = Buffer.create 64 in
  let flush_buf () =
    if Buffer.length buf > 0 then begin
      output (Buffer.contents buf);
      Buffer.clear buf
    end
  in
  let rec scan i =
    if i >= len then flush_buf ()
    else if Char.equal (String.get s i) '{' then
      match String.index_from s (i + 1) '}' with
      | None ->
        Buffer.add_char buf '{';
        scan (i + 1)
      | Some j ->
        let tag = String.sub s ~pos:(i + 1) ~len:(j - i - 1) in
        (match color_of_tag tag with
         | Some color ->
           flush_buf ();
           set_color color;
           scan (j + 1)
         | None ->
           (* Unknown tag — pass through as literal *)
           Buffer.add_string buf (String.sub s ~pos:i ~len:(j - i + 1));
           scan (j + 1))
    else begin
      Buffer.add_char buf (String.get s i);
      scan (i + 1)
    end
  in
  scan 0

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
  | effect (Set_color c), k ->
    Out_channel.(output_string stdout (ansi_code_of_color c); flush stdout);
    continue k ()
  | effect (Run_command cmd), k ->
    continue k @@ run_command_impl cmd
  | effect (Http_post { url; headers; body }), k ->
    continue k @@ Lwt_main.run @@ real_http_post ~url ~headers ~body
  | effect (Http_get { url; headers }), k ->
    continue k @@ Lwt_main.run @@ real_http_get ~url ~headers

module Mocked = struct
  open Effect.Deep

  type state =
    | Waiting_input of (string, unit) continuation
    | Waiting_http_get of (http_response, unit) continuation
    | Waiting_http_post of (http_response, unit) continuation
    | Finished

  type session = {
    mutable state : state;
    mutable resume : (unit -> unit) -> unit;
  }

  let run f =
    let session = {
      state = Finished;
      resume = (fun f -> f ())
    } in
    let handle thunk =
      try thunk () with
      | effect Input, k ->
          session.state <- Waiting_input k
      | effect Input_secret, k ->
          session.state <- Waiting_input k
      | effect (Set_color _), k ->
          continue k ()
      | effect (Http_get _), k ->
          session.state <- Waiting_http_get k
      | effect (Http_post _), k ->
          session.state <- Waiting_http_post k
    in
    session.resume <- handle;
    handle (fun () ->
      f ();
      session.state <- Finished);
    session

  let fail_wrong_step step session =
    failwith
    @@ Printf.sprintf "Tried to provide %s but program is %s" step
    @@ match session.state with
      | Waiting_input _ -> "waiting for input"
      | Waiting_http_get _ -> "performing GET"
      | Waiting_http_post _ -> "performing POST"
      | Finished -> "finished"

  let input session value =
    match session.state with
    | Waiting_input k ->
        session.resume @@ fun () -> Effect.Deep.continue k value
    | _ -> fail_wrong_step "input" session

  let http_get session response =
    match session.state with
    | Waiting_http_get k ->
        session.resume @@ fun () -> Effect.Deep.continue k response
    | _ -> fail_wrong_step "GET" session

  let http_post session response =
    match session.state with
    | Waiting_http_post k ->
        session.resume @@ fun () -> Effect.Deep.continue k response
    | _ -> fail_wrong_step "POST" session

  let finish session =
    match session.state with
    | Finished -> ()
    | _ -> fail_wrong_step "finish" session
end

let run_styled s =
  let open Effect.Deep in
  try styled s with
  | effect (Output s), k -> print_string s; continue k ()
  | effect (Set_color c), k ->
    let tag = match c with
      | Reset -> "/)" | Bold -> "(B" | Dim -> "(D" | Red -> "(R"
      | Green -> "(G" | Yellow -> "(Y" | Blue -> "(U" | Cyan -> "(C"
    in
    print_string tag; continue k ()

let%expect_test "styled: plain text" =
  run_styled "hello world";
  [%expect {| hello world |}]

let%expect_test "styled: tagged text" =
  run_styled "{ok}OK{/} done";
  [%expect {| (GOK/) done |}]

let%expect_test "styled: multiple tags" =
  run_styled "{header}=== Summary ==={/}\n{err}FAILED{/}";
  [%expect {|
    (B=== Summary ===/)
    (RFAILED/)
    |}]

let%expect_test "styled: unknown tag passes through" =
  run_styled "hello {unknown} world";
  [%expect {| hello {unknown} world |}]

let%expect_test "styled: unclosed brace passes through" =
  run_styled "hello { world";
  [%expect {| hello { world |}]
