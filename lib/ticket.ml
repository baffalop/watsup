open! Core

let ticket_re = Re.Pcre.regexp {|^[A-Z]+-[0-9]+$|}

let is_ticket_pattern s = Re.execp ticket_re s

let extract_tickets tags = List.filter tags ~f:is_ticket_pattern

let%expect_test "is_ticket_pattern valid" =
  print_s [%sexp (is_ticket_pattern "DEV-101" : bool)];
  [%expect {| true |}];
  print_s [%sexp (is_ticket_pattern "PROJ-850" : bool)];
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
  print_s [%sexp (is_ticket_pattern "DEV101" : bool)];
  [%expect {| false |}]

let%expect_test "extract_tickets" =
  let tags = [ "PROJ-850"; "DEV-101"; "jack"; "liam"; "DEV-202" ] in
  let tickets = extract_tickets tags in
  print_s [%sexp (tickets : string list)];
  [%expect {| (PROJ-850 DEV-101 DEV-202) |}]
