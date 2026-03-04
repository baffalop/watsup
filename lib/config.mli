type mapping =
  | Ticket of Ticket.Key.t
  | Skip
[@@deriving sexp]

type category_cache = {
  options : Category.t list;
  fetched_at : string;
}
[@@deriving sexp]

type t = {
  tempo_token : string;
  jira_email : string;
  jira_token : string;
  jira_base_url : string;
  jira_account_id : string;  (* Cached after first lookup *)
  issue_ids : (Ticket.Key.t * int) list;  (* ticket key -> numeric ID cache *)
  account_keys : (Ticket.Key.t * string) list;  (* ticket key -> Tempo account key *)
  tempo_account_attr_key : string;  (* cached Tempo work attribute key for Account *)
  tempo_category_attr_key : string;  (* cached Tempo work attribute key for Category *)
  categories : category_cache option;
  category_selections : (Ticket.Key.t * string) list;  (* ticket -> category value *)
  starred_projects : string list option;
  mappings : (string * mapping) list;
}
[@@deriving sexp]

(* Note: All fields have defaults for backwards compatibility with old configs *)

val default_path : unit -> string
val load : path:string -> t Core.Or_error.t
val save : path:string -> t -> unit Core.Or_error.t
val empty : t
val get_mapping : t -> string -> mapping option
val set_mapping : t -> string -> mapping -> t
val get_issue_id : t -> Ticket.Key.t -> int option
val set_issue_id : t -> Ticket.Key.t -> int -> t
val get_account_key : t -> Ticket.Key.t -> string option
val set_account_key : t -> Ticket.Key.t -> string -> t
val get_category_selection : t -> Ticket.Key.t -> string option
val set_category_selection : t -> Ticket.Key.t -> string -> t
