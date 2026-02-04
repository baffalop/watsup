type http_response = {
  status : int;
  body : string;
}

type t = {
  input : unit -> string;
  output : string -> unit;
  run_command : string -> string;  (* Execute shell command, return output *)
  http_post : url:string -> headers:(string * string) list -> body:string -> http_response Lwt.t;
}

val stdio : t
val create :
  input:(unit -> string) ->
  output:(string -> unit) ->
  run_command:(string -> string) ->
  http_post:(url:string -> headers:(string * string) list -> body:string -> http_response Lwt.t) ->
  t
