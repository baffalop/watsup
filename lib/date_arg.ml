open! Core

let all_digits s = (not (String.is_empty s)) && String.for_all s ~f:Char.is_digit
let short_digits s = all_digits s && String.length s <= 2

let create ~y ~m ~d =
  match Month.of_int m with
  | None -> None
  | Some m -> Option.try_with (fun () -> Date.create_exn ~y ~m ~d)

(* Use [current] unless it's in the future, in which case use [previous]. *)
let not_after ~today ~current ~previous =
  match current with
  | Some d when Date.( > ) d today -> previous ()
  | d -> d

let parse ~today s =
  let date =
    match String.split (String.strip s) ~on:'-' with
    | [ "0" ] -> Some today
    | [ ""; n ] when all_digits n && String.length n <= 5 ->
      Some (Date.add_days today (-Int.of_string n))
    | [ d ] when short_digits d ->
      let d = Int.of_string d in
      let in_month date =
        create ~y:(Date.year date) ~m:(Month.to_int (Date.month date)) ~d
      in
      not_after ~today ~current:(in_month today) ~previous:(fun () ->
        in_month (Date.add_months today (-1)))
    | [ m; d ] when short_digits m && short_digits d ->
      let m = Int.of_string m and d = Int.of_string d in
      let y = Date.year today in
      not_after ~today ~current:(create ~y ~m ~d) ~previous:(fun () ->
        create ~y:(y - 1) ~m ~d)
    | [ y; m; d ] when all_digits y && String.length y = 4 && short_digits m && short_digits d ->
      create ~y:(Int.of_string y) ~m:(Int.of_string m) ~d:(Int.of_string d)
    | _ -> None
  in
  match date with
  | Some d -> Ok d
  | None ->
    Or_error.errorf
      "Invalid date %S (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)" s

let%expect_test "parse" =
  let test ?(today = "2026-10-08") s =
    match parse ~today:(Date.of_string today) s with
    | Ok d -> print_endline (Date.to_string d)
    | Error e -> print_endline (Error.to_string_hum e)
  in
  (* relative *)
  test "0";
  [%expect {| 2026-10-08 |}];
  test "-1";
  [%expect {| 2026-10-07 |}];
  test "-3";
  [%expect {| 2026-10-05 |}];
  test "-40";
  [%expect {| 2026-08-29 |}];
  test "-0";
  [%expect {| 2026-10-08 |}];
  (* full ISO date *)
  test "2026-02-05";
  [%expect {| 2026-02-05 |}];
  test "2027-01-01";
  [%expect {| 2027-01-01 |}];
  (* MM-DD *)
  test "10-06";
  [%expect {| 2026-10-06 |}];
  test "10-08";
  [%expect {| 2026-10-08 |}];
  test "1-5";
  [%expect {| 2026-01-05 |}];
  test "10-09";
  [%expect {| 2025-10-09 |}];
  test ~today:"2026-01-02" "12-30";
  [%expect {| 2025-12-30 |}];
  test ~today:"2028-03-01" "02-29";
  [%expect {| 2028-02-29 |}];
  test ~today:"2027-03-01" "02-29";
  [%expect {| Invalid date "02-29" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago) |}];
  (* DD *)
  test "5";
  [%expect {| 2026-10-05 |}];
  test "08";
  [%expect {| 2026-10-08 |}];
  test "20";
  [%expect {| 2026-09-20 |}];
  test ~today:"2026-01-02" "31";
  [%expect {| 2025-12-31 |}];
  (* invalid *)
  List.iter ~f:test
    [ ""; "abc"; "+3"; "3 days"; "13-01"; "02-30"; "00"; "32"; "1-2-3"; "26-10-08";
      "-"; "--3"; "-1e3"; "-999999" ];
  [%expect {|
    Invalid date "" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "abc" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "+3" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "3 days" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "13-01" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "02-30" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "00" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "32" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "1-2-3" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "26-10-08" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "-" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "--3" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "-1e3" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    Invalid date "-999999" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago)
    |}]

let resolve ~today ~day ~from_date ~to_date =
  let open Or_error.Let_syntax in
  match day, from_date, to_date with
  | None, None, None -> Ok [ today ]
  | Some d, None, None ->
    let%map d = parse ~today d in
    [ d ]
  | None, Some f, t ->
    let%bind start = parse ~today f in
    let%bind stop = Option.value_map t ~default:(Ok today) ~f:(parse ~today) in
    if Date.( > ) start stop then
      Or_error.errorf "--from %s is after --to %s" (Date.to_string start) (Date.to_string stop)
    else Ok (Date.dates_between ~min:start ~max:stop)
  | Some _, _, _ -> Or_error.error_string "--day can't be combined with --from/--to"
  | None, None, Some _ -> Or_error.error_string "--to requires --from"

let%expect_test "resolve" =
  let test ?(today = "2026-10-08") ?day ?from ?to_ () =
    match resolve ~today:(Date.of_string today) ~day ~from_date:from ~to_date:to_ with
    | Ok dates -> print_endline (String.concat ~sep:" " (List.map dates ~f:Date.to_string))
    | Error e -> print_endline (Error.to_string_hum e)
  in
  test ();
  [%expect {| 2026-10-08 |}];
  test ~day:"-2" ();
  [%expect {| 2026-10-06 |}];
  test ~day:"2026-02-05" ();
  [%expect {| 2026-02-05 |}];
  test ~from:"-3" ~to_:"0" ();
  [%expect {| 2026-10-05 2026-10-06 2026-10-07 2026-10-08 |}];
  test ~from:"10-06" ~to_:"10-08" ();
  [%expect {| 2026-10-06 2026-10-07 2026-10-08 |}];
  test ~from:"2026-09-29" ~to_:"10-02" ();
  [%expect {| 2026-09-29 2026-09-30 2026-10-01 2026-10-02 |}];
  test ~from:"-2" ();
  [%expect {| 2026-10-06 2026-10-07 2026-10-08 |}];
  test ~from:"0" ~to_:"0" ();
  [%expect {| 2026-10-08 |}];
  test ~today:"2026-01-02" ~from:"12-30" ~to_:"01-02" ();
  [%expect {| 2025-12-30 2025-12-31 2026-01-01 2026-01-02 |}];
  (* errors *)
  test ~from:"10-08" ~to_:"10-06" ();
  [%expect {| --from 2026-10-08 is after --to 2026-10-06 |}];
  test ~from:"-1" ~to_:"-3" ();
  [%expect {| --from 2026-10-07 is after --to 2026-10-05 |}];
  test ~from:"bad" ~to_:"0" ();
  [%expect {| Invalid date "bad" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago) |}];
  test ~from:"0" ~to_:"bad" ();
  [%expect {| Invalid date "bad" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago) |}];
  test ~day:"bad" ();
  [%expect {| Invalid date "bad" (expected YYYY-MM-DD, MM-DD, DD, 0 for today or -N for N days ago) |}];
  test ~day:"0" ~from:"-1" ();
  [%expect {| --day can't be combined with --from/--to |}];
  test ~day:"0" ~to_:"-1" ();
  [%expect {| --day can't be combined with --from/--to |}];
  test ~to_:"0" ();
  [%expect {| --to requires --from |}]
