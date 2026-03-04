val fetch_work_attribute_keys : token:string -> (string option * string option, string) result
val fetch_category_options : token:string -> attr_key:string -> (Category.t list, string) result
val fetch_account_key : token:string -> account_id:string -> (string, string) result

val build_worklog_json :
  issue_id:int -> author_account_id:string -> duration_seconds:int ->
  date:string -> description:string -> attributes:(string * string) list -> string

val post_worklog :
  token:string -> issue_id:int -> author_account_id:string ->
  duration:Duration.t -> date:string -> description:string ->
  attributes:(string * string) list -> Io.http_response

(** Exposed for unit testing *)
val parse_work_attribute_keys_json : Yojson.Safe.t -> (string option * string option, string) result
val parse_category_options_json : Yojson.Safe.t -> (Category.t list, string) result
