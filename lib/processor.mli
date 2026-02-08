type decision =
  | Post of { ticket : string; duration : Duration.t; source : string; description : string }
  | Skip of { project : string; duration : Duration.t }
[@@deriving sexp]

type prompt_response =
  | Accept of string  (* ticket *)
  | Skip_once
  | Skip_always
  | Split
[@@deriving sexp]

type tag_prompt_response =
  | Tag_accept of string  (* ticket *)
  | Tag_skip
[@@deriving sexp]

(** Process a single entry given cached mapping and user prompt function *)
val process_entry :
  entry:Watson.entry ->
  cached:Config.mapping option ->
  prompt:(Watson.entry -> prompt_response) ->
  ?tag_prompt:(Watson.tag -> tag_prompt_response) ->
  ?describe:(string -> string) ->
  unit ->
  decision list * Config.mapping option  (* decisions and optional new mapping *)
