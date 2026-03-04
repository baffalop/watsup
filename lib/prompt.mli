type cached_response = Keep | Change_ticket | Change_category | Skip_once | Split

val cached_entry :
  creds:Jira_api.creds -> ticket:Ticket.Key.t -> has_tags:bool ->
  cached_response * bool

val cached_skip : unit -> cached_response

val uncached_entry :
  creds:Jira_api.creds -> starred_projects:string list ->
  date:string -> Watson.entry -> Processor.prompt_response

val uncached_tag :
  creds:Jira_api.creds -> starred_projects:string list ->
  date:string -> project:string -> Watson.tag -> Processor.tag_prompt_response

val cached_tag :
  creds:Jira_api.creds -> Watson.tag -> ticket:Ticket.Key.t ->
  cached_response * bool

val description : Ticket.Key.t -> string

val category_list :
  options:Category.t list -> current_value:string option -> string

val category :
  config:Config.t -> options:Category.t list -> Ticket.Key.t -> Config.t
