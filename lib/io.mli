type t = {
  input : unit -> string;
  output : string -> unit;
  run_command : string -> string;  (* Execute shell command, return output *)
}

val stdio : t
val create :
  input:(unit -> string) ->
  output:(string -> unit) ->
  run_command:(string -> string) ->
  t
