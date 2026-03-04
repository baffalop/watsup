type creds = {
  base_url : string;
  email : string;
  token : string;
}

val auth_header : creds:creds -> string * string
val fetch_account_id : creds:creds -> (string, string) result
val fetch_issue_info : creds:creds -> ticket:string -> (int * string option, string) result

(** Exposed for unit testing *)
val parse_issue_info_json : Yojson.Safe.t -> int * string option
