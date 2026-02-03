open Core

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

(* TODO: Implement actual API calls *)

let fetch_categories ~token:_ : category list Or_error.t Lwt.t =
  let cats : category list =
    [
      { id = 1; name = "Development" };
      { id = 2; name = "Meeting" };
      { id = 3; name = "Support" };
    ]
  in
  Lwt.return (Ok cats)

let fetch_account_for_ticket ~token:_ ~ticket:_ =
  Lwt.return (Ok (Some { id = 1; name = "Default Account" }))

let post_worklog ~token:_ _worklog = Lwt.return Worklog.Posted
