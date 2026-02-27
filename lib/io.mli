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

val input : unit -> string
val input_secret : unit -> string
val output : string -> unit
val run_command : string -> string
val http_post : url:string -> headers:(string * string) list -> body:string -> http_response
val http_get : url:string -> headers:(string * string) list -> http_response

val with_stdio : (unit -> 'a) -> 'a
