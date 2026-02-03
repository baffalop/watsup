open Core

let ticket_re = Re.Pcre.regexp {|^[A-Z]+-[0-9]+$|}

let is_ticket_pattern s = Re.execp ticket_re s

let extract_tickets tags = List.filter tags ~f:is_ticket_pattern

let%expect_test "is_ticket_pattern valid" =
  print_s [%sexp (is_ticket_pattern "FK-3080" : bool)];
  [%expect {| true |}];
  print_s [%sexp (is_ticket_pattern "CHIM-850" : bool)];
  [%expect {| true |}];
  print_s [%sexp (is_ticket_pattern "LOG-16" : bool)];
  [%expect {| true |}]

let%expect_test "is_ticket_pattern invalid" =
  print_s [%sexp (is_ticket_pattern "jack" : bool)];
  [%expect {| false |}];
  print_s [%sexp (is_ticket_pattern "tomasz" : bool)];
  [%expect {| false |}];
  print_s [%sexp (is_ticket_pattern "setup" : bool)];
  [%expect {| false |}];
  print_s [%sexp (is_ticket_pattern "FK3080" : bool)];
  [%expect {| false |}]

let%expect_test "extract_tickets" =
  let tags = [ "CHIM-850"; "FK-3080"; "jack"; "liam"; "FK-3083" ] in
  let tickets = extract_tickets tags in
  print_s [%sexp (tickets : string list)];
  [%expect {| (CHIM-850 FK-3080 FK-3083) |}]
