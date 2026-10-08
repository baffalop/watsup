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

let duration_p =
  let part suffix = digits <* char suffix <* ws in
  let* h = option None (part 'h' >>| Option.some) in
  let* m = option None (part 'm' >>| Option.some) in
  let* s = option None (part 's' >>| Option.some) in
  match (h, m, s) with
  | None, None, None -> fail "duration"
  | _ ->
    return
      (Duration.of_hms
         ~hours:(Option.value h ~default:0)
         ~mins:(Option.value m ~default:0)
         ~secs:(Option.value s ~default:0))

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

let tag_line =
  let* _ = char '\t' *> char '[' in
  let* name_chars, dur =
    fix (fun self ->
      (let* d = ws *> duration_p <* char ']' in
       return ([], d))
      <|> let* c = not_char '\n' in
          let* cs, d = self in
          return (c :: cs, d))
  in
  let name = String.of_char_list name_chars |> String.strip in
  return { name; duration = dur }

let%expect_test "parse tag line" =
  let test s =
    match parse_string ~consume:Prefix tag_line s with
    | Ok t -> print_s [%sexp (t : tag)]
    | Error e -> print_endline e
  in
  test "\t[setup  1h 29m 04s]";
  [%expect {| ((name setup) (duration 5344)) |}];
  test "\t[DEV-101     33m 35s]";
  [%expect {| ((name DEV-101) (duration 2015)) |}]

let project_line =
  let* name_chars, dur =
    fix (fun self ->
      (let* d = ws *> char '-' *> ws *> duration_p in
       return ([], d))
      <|> let* c = not_char '\n' in
          let* cs, d = self in
          return (c :: cs, d))
  in
  let name = String.of_char_list name_chars |> String.strip in
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
  [%expect {| (cr 3062) |}];
  test "ranting-and-raving - 03s";
  [%expect {| (ranting-and-raving 3) |}];
  test "maxim - 11s";
  [%expect {| (maxim 11) |}]

let newline = char '\n'

let entry_p =
  let* name, total = project_line <* newline in
  let* tags = many (tag_line <* newline) in
  let* _ = many newline in
  return { project = name; total; tags }

let test_entry s =
  match parse_string ~consume:Prefix entry_p s with
  | Ok e -> print_s [%sexp (e : entry)]
  | Error e -> print_endline e

let%expect_test "parse entry" =
  test_entry {|packaday - 2h 28m 32s
	[setup  1h 29m 04s]
	[shapes     59m 28s]
  |};
  [%expect
    {|
    ((project packaday) (total 8912)
     (tags (((name setup) (duration 5344)) ((name shapes) (duration 3568)))))
    |}]

let%expect_test "parse entry with arbitrary string tags" =
  test_entry {|packaday - 2h 28m 32s
	[string with spaces  20m 04s]
	[[in brackets]       10m 28s]
	[one bracket]        03m 58s]
	[[one bracket        08m 11s]
	[*all* sorts of "crazy stuff" 1h 5m 22s]
  |};
  [%expect {|
    ((project packaday) (total 8912)
     (tags
      (((name "string with spaces") (duration 1204))
       ((name "[in brackets]") (duration 628))
       ((name "one bracket]") (duration 238))
       ((name "[one bracket") (duration 491))
       ((name "*all* sorts of \"crazy stuff\"") (duration 3922)))))
    |}]

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
	[DEV-101     33m 35s]
	[DEV-202     12m 37s]

spec - 51m 02s
	[an "easy" problem  2h 6m 05s]

Total: 2h 37m 27s|}
  in
  match parse input with
  | Ok r ->
    print_s [%sexp (List.length r.entries : int)];
    [%expect {| 4 |}];
    print_s [%sexp (r.date_range : string)];
    [%expect {| "Tue 03 February 2026 -> Tue 03 February 2026" |}]
  | Error e -> print_s [%sexp (e : Error.t)]
