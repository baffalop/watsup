open Core

type decision =
  | Post of { ticket : string; duration : Duration.t; source : string; description : string }
  | Skip of { project : string; duration : Duration.t }
[@@deriving sexp]

type prompt_response =
  | Accept of string
  | Skip_once
  | Skip_always
  | Split
[@@deriving sexp]

type tag_prompt_response =
  | Tag_accept of string
  | Tag_skip
[@@deriving sexp]

let process_entry ~entry ~cached ~prompt ?(tag_prompt = fun _tag -> Tag_skip) ?(describe = fun _ticket -> "") () =
  match cached with
  | Some Config.Skip ->
    ([Skip { project = entry.Watson.project; duration = entry.total }], None)
  | Some (Config.Ticket ticket) ->
    let description = describe ticket in
    ([Post {
      ticket;
      duration = Duration.round_5min entry.total;
      source = entry.project;
      description;
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
          description = "";
        })
      | None -> None)
    in
    (decisions, None)
  | None ->
    let response = prompt entry in
    match response with
    | Accept ticket ->
      let description = describe ticket in
      ([Post {
        ticket;
        duration = Duration.round_5min entry.total;
        source = entry.project;
        description;
      }], Some (Config.Ticket ticket))
    | Skip_once ->
      ([], None)
    | Skip_always ->
      ([Skip { project = entry.project; duration = entry.total }], Some Config.Skip)
    | Split ->
      let decisions = List.filter_map entry.tags ~f:(fun tag ->
        match tag_prompt tag with
        | Tag_accept ticket ->
          let description = describe ticket in
          Some (Post {
            ticket;
            duration = Duration.round_5min tag.Watson.duration;
            source = sprintf "%s:%s" entry.project tag.name;
            description;
          })
        | Tag_skip -> None)
      in
      (* If all tags resolved to ticket patterns, cache as Auto_extract *)
      let all_tickets = List.for_all entry.tags ~f:(fun tag ->
        Ticket.is_ticket_pattern tag.name) in
      let mapping = if all_tickets && not (List.is_empty entry.tags)
        then Some Config.Auto_extract else None in
      (decisions, mapping)

let%expect_test "process_entry with cached ticket" =
  let entry = {
    Watson.project = "myproj";
    total = Duration.of_hms ~hours:1 ~mins:28 ~secs:0;
    tags = [];
  } in
  let decisions, mapping = process_entry
    ~entry
    ~cached:(Some (Config.Ticket "PROJ-123"))
    ~prompt:(fun _ -> failwith "should not prompt") () in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Post (ticket PROJ-123) (duration 5400) (source myproj) (description ""))) |}];
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
    ~prompt:(fun _ -> failwith "should not prompt") () in
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
    ~prompt:(fun _ -> Accept "NEW-456") () in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Post (ticket NEW-456) (duration 7200) (source newproj) (description ""))) |}];
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
    ~prompt:(fun _ -> failwith "should not prompt") () in
  print_s [%sexp (decisions : decision list)];
  [%expect {|
    ((Post (ticket FK-123) (duration 1800) (source cr:FK-123) (description ""))
     (Post (ticket FK-456) (duration 900) (source cr:FK-456) (description "")))
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
    ~prompt:(fun _ -> Skip_once) () in
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
    ~prompt:(fun _ -> Skip_always) () in
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
    ~prompt:(fun _ -> failwith "should not prompt") () in
  print_s [%sexp (decisions : decision list)];
  [%expect {| () |}]

let%expect_test "process_entry split assigns per-tag" =
  let entry = {
    Watson.project = "cr";
    total = Duration.of_hms ~hours:1 ~mins:0 ~secs:0;
    tags = [
      { Watson.name = "FK-3080"; duration = Duration.of_hms ~hours:0 ~mins:35 ~secs:0 };
      { Watson.name = "FK-3083"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
    ];
  } in
  let decisions, mapping = process_entry
    ~entry
    ~cached:None
    ~prompt:(fun _ -> Split)
    ~tag_prompt:(fun tag -> Tag_accept tag.Watson.name)
    () in
  print_s [%sexp (decisions : decision list)];
  [%expect {|
    ((Post (ticket FK-3080) (duration 2100) (source cr:FK-3080) (description ""))
     (Post (ticket FK-3083) (duration 900) (source cr:FK-3083) (description "")))
    |}];
  (* All tags are ticket patterns, so cache as Auto_extract *)
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| (Auto_extract) |}]

let%expect_test "process_entry split with mixed tags" =
  let entry = {
    Watson.project = "cr";
    total = Duration.of_hms ~hours:1 ~mins:0 ~secs:0;
    tags = [
      { Watson.name = "FK-3080"; duration = Duration.of_hms ~hours:0 ~mins:35 ~secs:0 };
      { Watson.name = "review"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
    ];
  } in
  let decisions, mapping = process_entry
    ~entry
    ~cached:None
    ~prompt:(fun _ -> Split)
    ~tag_prompt:(fun tag ->
      if String.equal tag.Watson.name "review" then Tag_skip
      else Tag_accept tag.name)
    () in
  print_s [%sexp (decisions : decision list)];
  [%expect {| ((Post (ticket FK-3080) (duration 2100) (source cr:FK-3080) (description ""))) |}];
  (* Not all tags are ticket patterns, so no cache *)
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| () |}]
