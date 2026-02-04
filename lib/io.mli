type t = {
  input : unit -> string;
  output : string -> unit;
}

val stdio : t
val create : input:(unit -> string) -> output:(string -> unit) -> t
