type category = {
  id : int;
  name : string;
}
[@@deriving sexp]

type account = {
  id : int;
  name : string;
}
[@@deriving sexp]

val fetch_categories : token:string -> category list Core.Or_error.t Lwt.t

val fetch_account_for_ticket :
  token:string -> ticket:string -> account option Core.Or_error.t Lwt.t

val post_worklog : token:string -> Worklog.t -> Worklog.post_result Lwt.t
