type decision =
  | Post of { ticket : string; duration : Duration.t; source : string }
  | Skip of { project : string; duration : Duration.t }
[@@deriving sexp]

type prompt_response =
  | Accept of string  (* ticket *)
  | Skip_once
  | Skip_always
[@@deriving sexp]

(** Process a single entry given cached mapping and user prompt function *)
val process_entry :
  entry:Watson.entry ->
  cached:Config.mapping option ->
  prompt:(Watson.entry -> prompt_response) ->
  decision list * Config.mapping option  (* decisions and optional new mapping *)
