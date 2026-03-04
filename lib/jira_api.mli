val auth_header : email:string -> token:string -> string * string
val fetch_account_id : config:Config.t -> (string, string) result
val fetch_issue_info : config:Config.t -> ticket:string -> (int * string option, string) result

(** Exposed for unit testing *)
val parse_issue_info_json : Yojson.Safe.t -> int * string option
