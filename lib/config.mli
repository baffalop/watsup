type mapping =
  | Ticket of string
  | Skip
  | Auto_extract
[@@deriving sexp]

type category_cache = {
  selected : string;  (* value key sent in POST *)
  options : (string * string) list;  (* (value, display_name) pairs *)
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
  account_keys : (string * string) list;  (* ticket key -> Tempo account key *)
  tempo_account_attr_key : string;  (* cached Tempo work attribute key for Account *)
  tempo_category_attr_key : string;  (* cached Tempo work attribute key for Category *)
  category : category_cache option;
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
val get_issue_id : t -> string -> int option
val set_issue_id : t -> string -> int -> t
val get_account_key : t -> string -> string option
val set_account_key : t -> string -> string -> t
