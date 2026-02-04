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
  jira_email : string;
  jira_token : string;
  jira_base_url : string;
  jira_account_id : string;  (* Cached after first lookup *)
  issue_ids : (string * int) list;  (* ticket key -> numeric ID cache *)
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
val get_issue_id : t -> string -> int option
val set_issue_id : t -> string -> int -> t
