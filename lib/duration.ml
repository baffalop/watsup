open Core

type t = int [@@deriving sexp, compare, equal] (* seconds *)

let of_hms ~hours ~mins ~secs = (hours * 3600) + (mins * 60) + secs
let of_seconds s = s
let to_seconds t = t
let to_minutes t = t / 60
let zero = 0
let ( + ) = Int.( + )

let round_5min t =
  let mins = to_minutes t in
  let rounded = ((mins + 2) / 5) * 5 in
  of_seconds (rounded * 60)

let to_string t =
  let total_mins = to_minutes t in
  let hours = total_mins / 60 in
  let mins = total_mins mod 60 in
  match hours, mins with
  | 0, m -> sprintf "%dm" m
  | h, 0 -> sprintf "%dh" h
  | h, m -> sprintf "%dh %dm" h m

let%expect_test "of_hms" =
  let d = of_hms ~hours:2 ~mins:28 ~secs:32 in
  print_s [%sexp (to_seconds d : int)];
  [%expect {| 8912 |}]

let%expect_test "round_5min rounds up from 3" =
  let d = of_hms ~hours:0 ~mins:28 ~secs:0 in
  let rounded = round_5min d in
  print_s [%sexp (to_minutes rounded : int)];
  [%expect {| 30 |}]

let%expect_test "round_5min rounds down from 2" =
  let d = of_hms ~hours:0 ~mins:32 ~secs:0 in
  let rounded = round_5min d in
  print_s [%sexp (to_minutes rounded : int)];
  [%expect {| 30 |}]

let%expect_test "round_5min 33 -> 35" =
  let d = of_hms ~hours:0 ~mins:33 ~secs:0 in
  let rounded = round_5min d in
  print_s [%sexp (to_minutes rounded : int)];
  [%expect {| 35 |}]

let%expect_test "to_string" =
  print_endline (to_string (of_hms ~hours:2 ~mins:30 ~secs:0));
  [%expect {| 2h 30m |}];
  print_endline (to_string (of_hms ~hours:0 ~mins:45 ~secs:0));
  [%expect {| 45m |}];
  print_endline (to_string (of_hms ~hours:1 ~mins:0 ~secs:0));
  [%expect {| 1h |}]
