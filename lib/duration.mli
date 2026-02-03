open! Core

type t [@@deriving sexp, compare, equal]

val of_hms : hours:int -> mins:int -> secs:int -> t
val of_seconds : int -> t
val to_seconds : t -> int
val to_minutes : t -> int
val round_5min : t -> t
val to_string : t -> string
val zero : t
val ( + ) : t -> t -> t
