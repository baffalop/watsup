type search_result = { key : Ticket.Key.t; summary : string; id : int }

type prompt_outcome =
  | Selected of search_result
  | Skip_once
  | Skip_always
  | Split

type lookup_result =
  | Found of search_result
  | Not_found of string

val lookup_cached_ticket : creds:Jira_api.creds -> ticket:Ticket.Key.t -> lookup_result
val prompt_loop : creds:Jira_api.creds -> search_hint:string -> has_tags:bool -> starred_projects:string list -> log_date:string -> prompt_outcome
