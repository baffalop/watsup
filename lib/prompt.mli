type action =
  | Accept of string
  | Skip
  | Skip_always
  | Split
  | Set_message of string
  | Change_category
  | Quit
[@@deriving sexp]

val prompt_entry :
  Watson.entry -> cached:Config.mapping option -> category:string -> action

val prompt_tag : project:string -> Watson.tag -> action
val prompt_ticket : default:string option -> string

val prompt_confirm_post :
  Worklog.t list ->
  skipped:(string * Duration.t) list ->
  manual:(string * Duration.t) list ->
  bool

val prompt_token : unit -> string
val prompt_category : Tempo.category list -> current:string option -> string
