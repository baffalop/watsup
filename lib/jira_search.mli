type search_result = { key : string; summary : string; id : int }

type prompt_outcome =
  | Selected of search_result
  | Skip_once
  | Skip_always
  | Split

type lookup_result =
  | Found of search_result
  | Not_found of string

val sanitize_jql_text : string -> string option
val validate_project_key : string -> bool
val build_search_jql : terms:string -> starred_projects:string list -> log_date:string -> string option
val parse_search_results : string -> search_result list
val parse_single_issue : string -> (search_result, string) result
val search : creds:Jira_api.creds -> jql:string -> (search_result list, string) result
val lookup : creds:Jira_api.creds -> ticket:string -> (search_result, string) result
val lookup_cached_ticket : creds:Jira_api.creds -> ticket:string -> lookup_result
val prompt_loop : creds:Jira_api.creds -> search_hint:string -> has_tags:bool -> starred_projects:string list -> log_date:string -> prompt_outcome
