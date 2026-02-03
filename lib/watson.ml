open! Core
open Angstrom

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

(* Parser combinators *)

let ws = skip_while (fun c -> Char.equal c ' ')
let digits = take_while1 Char.is_digit >>| Int.of_string

let duration_part suffix = option 0 (digits <* char suffix <* ws)

let duration_p =
  let* hours = duration_part 'h' in
  let* mins = duration_part 'm' in
  let* secs = duration_part 's' in
  return (Duration.of_hms ~hours ~mins ~secs)

let%expect_test "parse duration" =
  let test s =
    match parse_string ~consume:Prefix duration_p s with
    | Ok d -> print_s [%sexp (Duration.to_seconds d : int)]
    | Error e -> print_endline e
  in
  test "2h 28m 32s";
  [%expect {| 8912 |}];
  test "1h 29m 04s";
  [%expect {| 5344 |}];
  test "59m 28s";
  [%expect {| 3568 |}];
  test "25m 46s";
  [%expect {| 1546 |}]

let tag_name =
  take_while1 (fun c -> (not (Char.is_whitespace c)) && not (Char.equal c ']'))

let tag_line =
  let* _ = char '\t' *> char '[' in
  let* name = tag_name <* ws in
  let* dur = duration_p <* char ']' in
  return { name; duration = dur }

let%expect_test "parse tag line" =
  let test s =
    match parse_string ~consume:Prefix tag_line s with
    | Ok t -> print_s [%sexp (t : tag)]
    | Error e -> print_endline e
  in
  test "\t[setup  1h 29m 04s]";
  [%expect {| ((name setup) (duration 5344)) |}];
  test "\t[FK-3080     33m 35s]";
  [%expect {| ((name FK-3080) (duration 2015)) |}]

let project_name =
  take_while1 (fun c -> (not (Char.is_whitespace c)) && not (Char.equal c '-'))

let project_line =
  let* name = project_name <* ws in
  let* _ = char '-' <* ws in
  let* dur = duration_p in
  return (name, dur)

let%expect_test "parse project line" =
  let test s =
    match parse_string ~consume:Prefix project_line s with
    | Ok (name, dur) ->
      print_s [%sexp ((name, Duration.to_seconds dur) : string * int)]
    | Error e -> print_endline e
  in
  test "packaday - 2h 28m 32s";
  [%expect {| (packaday 8912) |}];
  test "cr - 51m 02s";
  [%expect {| (cr 3062) |}]

let newline = char '\n'

let entry_p =
  let* name, total = project_line <* newline in
  let* tags = many (tag_line <* newline) in
  let* _ = many newline in
  return { project = name; total; tags }

let%expect_test "parse entry" =
  let input =
    "packaday - 2h 28m 32s\n\t[setup  1h 29m 04s]\n\t[shapes     59m 28s]\n"
  in
  match parse_string ~consume:Prefix entry_p input with
  | Ok e ->
    print_s [%sexp (e : entry)];
    [%expect
      {|
      ((project packaday) (total 8912)
       (tags (((name setup) (duration 5344)) ((name shapes) (duration 3568)))))
      |}]
  | Error e -> print_endline e

let date_range_line = take_till (Char.equal '\n') <* newline
let blank_line = newline

let total_line =
  let* _ = string "Total: " in
  duration_p

let report_p =
  let* date_range = date_range_line in
  let* _ = blank_line in
  let* entries = many entry_p in
  let* total = total_line in
  return { date_range; entries; total }

let parse input =
  match parse_string ~consume:Prefix report_p input with
  | Ok report -> Ok report
  | Error msg -> Or_error.error_string msg

let%expect_test "parse full report" =
  let input =
    {|Tue 03 February 2026 -> Tue 03 February 2026

architecture - 25m 46s

breaks - 1h 20m 39s
	[coffee     20m 55s]
	[lunch     59m 44s]

cr - 51m 02s
	[FK-3080     33m 35s]
	[FK-3083     12m 37s]

Total: 2h 37m 27s|}
  in
  match parse input with
  | Ok r ->
    print_s [%sexp (List.length r.entries : int)];
    [%expect {| 3 |}];
    print_s [%sexp (r.date_range : string)];
    [%expect {| "Tue 03 February 2026 -> Tue 03 February 2026" |}]
  | Error e -> print_s [%sexp (e : Error.t)]
