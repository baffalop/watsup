open Core

type t = {
  ticket : string;
  duration : Duration.t;
  date : Date.t;
  category : Category.t;
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
