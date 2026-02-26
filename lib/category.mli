type t [@@deriving sexp]

val make : value:string -> name:string -> t

val value : t -> string
val name : t -> string
