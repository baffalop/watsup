type decision =
  | Post of { ticket : Ticket.Key.t; duration : Duration.t; source : string; description : string }
  | Skip of { project : string; duration : Duration.t }
[@@deriving sexp]

type prompt_response =
  | Accept of Ticket.Key.t
  | Skip_once
  | Skip_always
  | Split
[@@deriving sexp]

type tag_prompt_response =
  | Tag_accept of Ticket.Key.t
  | Tag_skip
[@@deriving sexp]

(** Sum durations of all Post decisions, excluding Skips *)
val total_posted_duration : decision list -> Duration.t

(** Process a single entry given cached mapping and user prompt function *)
type entry_resolution =
  | Project_cached of Ticket.Key.t
  | Project_skip
  | Tag_inferred of Ticket.Key.t
  | Auto_split
  | Uncached
[@@deriving sexp]

(** Resolve how an entry should be handled based on config mappings and tag patterns *)
val resolve_entry_mapping :
  config:Config.t ->
  project:string ->
  tags:Watson.tag list ->
  entry_resolution

val process_entry :
  entry:Watson.entry ->
  cached:Config.mapping option ->
  prompt:(Watson.entry -> prompt_response) ->
  ?tag_prompt:(Watson.tag -> tag_prompt_response) ->
  ?describe:(Ticket.Key.t -> string) ->
  unit ->
  decision list * Config.mapping option  (* decisions and optional new mapping *)
