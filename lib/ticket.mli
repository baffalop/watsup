open! Core

module Key : sig
  type t [@@deriving sexp]
  val of_string : string -> t option
  val of_string_exn : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
end

val is_project_key : string -> bool
val is_ticket_pattern : string -> bool
val extract_tickets : string list -> Key.t list
