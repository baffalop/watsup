type t = {
  ticket : string;
  duration : Duration.t;
  date : Core.Date.t;
  category : string;
  account : string option;
  message : string option;
  source : string;
}
[@@deriving sexp]

type post_result =
  | Posted
  | Failed of string
  | Manual_required of string
[@@deriving sexp]
