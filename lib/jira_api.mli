type creds = {
  base_url : string;
  email : string;
  token : string;
}

val auth_header : creds:creds -> string * string
val fetch_account_id : creds:creds -> (string, string) result
val fetch_issue_info : creds:creds -> ticket:Ticket.Key.t -> (int * string option, string) result
