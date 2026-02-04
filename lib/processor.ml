open Core

type decision =
  | Post of { ticket : string; duration : Duration.t; source : string }
  | Skip of { project : string; duration : Duration.t }
[@@deriving sexp]

type prompt_response =
  | Accept of string
  | Skip_once
  | Skip_always
[@@deriving sexp]

let process_entry ~entry ~cached ~prompt =
  match cached with
  | Some Config.Skip ->
    ([Skip { project = entry.Watson.project; duration = entry.total }], None)
  | Some (Config.Ticket ticket) ->
    ([Post {
      ticket;
      duration = Duration.round_5min entry.total;
      source = entry.project
    }], None)
  | Some Config.Auto_extract ->
    let tickets = List.map entry.tags ~f:(fun t -> t.Watson.name)
      |> Ticket.extract_tickets in
    let decisions = List.filter_map tickets ~f:(fun ticket ->
      match List.find entry.tags ~f:(fun t -> String.equal t.name ticket) with
      | Some tag -> Some (Post {
          ticket;
          duration = Duration.round_5min tag.duration;
          source = sprintf "%s:%s" entry.project ticket;
        })
      | None -> None)
    in
    (decisions, None)
  | None ->
    let response = prompt entry in
    match response with
    | Accept ticket ->
      ([Post {
        ticket;
        duration = Duration.round_5min entry.total;
        source = entry.project
      }], Some (Config.Ticket ticket))
    | Skip_once ->
      ([], None)
    | Skip_always ->
      ([Skip { project = entry.project; duration = entry.total }], Some Config.Skip)

let%expect_test "process_entry with cached ticket" =
  let entry = {
    Watson.project = "myproj";
    total = Duration.of_hms ~hours:1 ~mins:28 ~secs:0;
    tags = [];
  } in
  let decisions, mapping = process_entry
    ~entry
    ~cached:(Some (Config.Ticket "PROJ-123"))
    ~prompt:(fun _ -> failwith "should not prompt") in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Post (ticket PROJ-123) (duration 5400) (source myproj))) |}];
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| () |}]

let%expect_test "process_entry with cached skip" =
  let entry = {
    Watson.project = "breaks";
    total = Duration.of_hms ~hours:0 ~mins:45 ~secs:0;
    tags = [];
  } in
  let decisions, _ = process_entry
    ~entry
    ~cached:(Some Config.Skip)
    ~prompt:(fun _ -> failwith "should not prompt") in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Skip (project breaks) (duration 2700))) |}]

let%expect_test "process_entry prompts when no cache" =
  let entry = {
    Watson.project = "newproj";
    total = Duration.of_hms ~hours:2 ~mins:0 ~secs:0;
    tags = [];
  } in
  let decisions, mapping = process_entry
    ~entry
    ~cached:None
    ~prompt:(fun _ -> Accept "NEW-456") in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Post (ticket NEW-456) (duration 7200) (source newproj))) |}];
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| ((Ticket NEW-456)) |}]

let%expect_test "process_entry auto_extract" =
  let entry = {
    Watson.project = "cr";
    total = Duration.of_hms ~hours:1 ~mins:0 ~secs:0;
    tags = [
      { Watson.name = "FK-123"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
      { Watson.name = "review"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
      { Watson.name = "FK-456"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
    ];
  } in
  let decisions, _ = process_entry
    ~entry
    ~cached:(Some Config.Auto_extract)
    ~prompt:(fun _ -> failwith "should not prompt") in
  print_s [%sexp (decisions : decision list)];
  [%expect {|
    ((Post (ticket FK-123) (duration 1800) (source cr:FK-123))
     (Post (ticket FK-456) (duration 900) (source cr:FK-456)))
    |}]

let%expect_test "process_entry skip_once response" =
  let entry = {
    Watson.project = "meeting";
    total = Duration.of_hms ~hours:0 ~mins:30 ~secs:0;
    tags = [];
  } in
  let decisions, mapping = process_entry
    ~entry
    ~cached:None
    ~prompt:(fun _ -> Skip_once) in
  print_s [%sexp (decisions : decision list)];
  [%expect {| () |}];
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| () |}]

let%expect_test "process_entry skip_always response" =
  let entry = {
    Watson.project = "lunch";
    total = Duration.of_hms ~hours:1 ~mins:0 ~secs:0;
    tags = [];
  } in
  let decisions, mapping = process_entry
    ~entry
    ~cached:None
    ~prompt:(fun _ -> Skip_always) in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Skip (project lunch) (duration 3600))) |}];
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| (Skip) |}]

let%expect_test "process_entry auto_extract with no ticket tags" =
  let entry = {
    Watson.project = "cr";
    total = Duration.of_hms ~hours:1 ~mins:0 ~secs:0;
    tags = [
      { Watson.name = "review"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
      { Watson.name = "meeting"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
    ];
  } in
  let decisions, _ = process_entry
    ~entry
    ~cached:(Some Config.Auto_extract)
    ~prompt:(fun _ -> failwith "should not prompt") in
  print_s [%sexp (decisions : decision list)];
  [%expect {| () |}]
