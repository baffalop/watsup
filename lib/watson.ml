open Core

type tag = {
  name : string;
  duration : Duration.t;
}
[@@deriving sexp]

type entry = {
  project : string;
  total : Duration.t;
  tags : tag list;
}
[@@deriving sexp]

type report = {
  date_range : string;
  entries : entry list;
  total : Duration.t;
}
[@@deriving sexp]

let parse _input = Or_error.error_string "not implemented"
