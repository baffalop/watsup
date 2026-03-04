type creds

val make_creds : token:string -> author_account_id:string -> creds

val fetch_work_attribute_keys : creds:creds -> (string option * string option, string) result
val fetch_category_options : creds:creds -> attr_key:string -> (Category.t list, string) result
val fetch_account_key : creds:creds -> account_id:string -> (string, string) result

val post_worklog :
  creds:creds -> issue_id:int ->
  duration:Duration.t -> date:string -> description:string ->
  attributes:(string * string) list -> Io.http_response
