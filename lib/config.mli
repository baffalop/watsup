type mapping =
  | Ticket of string
  | Skip
  | Auto_extract
[@@deriving sexp]

type category_cache = {
  selected : string;
  options : string list;
  fetched_at : string;
}
[@@deriving sexp]

type t = {
  tempo_token : string;
  category : category_cache option;
  mappings : (string * mapping) list;
}
[@@deriving sexp]

val default_path : unit -> string
val load : path:string -> t Core.Or_error.t
val save : path:string -> t -> unit Core.Or_error.t
val empty : t
val get_mapping : t -> string -> mapping option
val set_mapping : t -> string -> mapping -> t
