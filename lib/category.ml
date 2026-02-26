open Base

type t = {
  value : string;
  name : string;
} [@@deriving sexp]

let make ~value ~name : t = { value; name }

let value t = t.value
let name t = t.name
