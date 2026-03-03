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
      (decisions, None)

let total_posted_duration decisions =
  List.fold decisions ~init:Duration.zero ~f:(fun acc -> function
    | Post { duration; _ } -> Duration.(acc + duration)
    | Skip _ -> acc)

let%expect_test "total_posted_duration excludes skips" =
  let decisions = [
    Post { ticket = "PROJ-1"; duration = Duration.of_hms ~hours:1 ~mins:0 ~secs:0; source = "a"; description = "" };
    Skip { project = "breaks"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
    Post { ticket = "PROJ-2"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0; source = "b"; description = "" };
  ] in
  print_endline @@ Duration.to_string @@ total_posted_duration decisions;
  [%expect {| 1h 30m |}]

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

let%expect_test "process_entry split assigns per-tag" =
  let entry = {
    Watson.project = "cr";
    total = Duration.of_hms ~hours:1 ~mins:0 ~secs:0;
    tags = [
      { Watson.name = "DEV-101"; duration = Duration.of_hms ~hours:0 ~mins:35 ~secs:0 };
      { Watson.name = "DEV-202"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
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
    ((Post (ticket DEV-101) (duration 2100) (source cr:DEV-101) (description ""))
     (Post (ticket DEV-202) (duration 900) (source cr:DEV-202) (description "")))
    |}];
  (* No entry-level mapping for splits *)
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| () |}]

type entry_resolution =
  | Project_cached of string
  | Project_skip
  | Tag_inferred of string
  | Auto_split
  | Uncached
[@@deriving sexp]

let resolve_entry_mapping ~(config : Config.t) ~project ~(tags : Watson.tag list) =
  let project_mapping = Config.get_mapping config project in
  match project_mapping with
  | Some (Config.Ticket ticket) -> Project_cached ticket
  | Some Config.Skip -> Project_skip
  | None when Ticket.is_ticket_pattern project -> Project_cached project
  | None ->
    let mapped_tags = List.filter_map tags ~f:(fun tag ->
      let composite_key = sprintf "%s:%s" project tag.Watson.name in
      match Config.get_mapping config composite_key with
      | Some (Config.Ticket ticket) -> Some ticket
      | Some Config.Skip -> None
      | None when Ticket.is_ticket_pattern tag.Watson.name -> Some tag.Watson.name
      | None -> None)
    in
    (match mapped_tags with
     | [] -> Uncached
     | [ticket] -> Tag_inferred ticket
     | _ -> Auto_split)

let%expect_test "resolve: project cached ticket" =
  let config = { Config.empty with mappings = [("myproj", Config.Ticket "PROJ-123")] } in
  let result = resolve_entry_mapping ~config ~project:"myproj" ~tags:[] in
  print_s [%sexp (result : entry_resolution)];
  [%expect {| (Project_cached PROJ-123) |}]

let%expect_test "resolve: project skip" =
  let config = { Config.empty with mappings = [("breaks", Config.Skip)] } in
  let result = resolve_entry_mapping ~config ~project:"breaks" ~tags:[] in
  print_s [%sexp (result : entry_resolution)];
  [%expect {| Project_skip |}]

let%expect_test "resolve: project is ticket pattern" =
  let config = Config.empty in
  let result = resolve_entry_mapping ~config ~project:"DEV-42" ~tags:[] in
  print_s [%sexp (result : entry_resolution)];
  [%expect {| (Project_cached DEV-42) |}]

let%expect_test "resolve: one tag with composite mapping" =
  let config = { Config.empty with mappings = [("cr:DEV-101", Config.Ticket "DEV-101")] } in
  let tags = [
    { Watson.name = "DEV-101"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
    { Watson.name = "review"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
  ] in
  let result = resolve_entry_mapping ~config ~project:"cr" ~tags in
  print_s [%sexp (result : entry_resolution)];
  [%expect {| (Tag_inferred DEV-101) |}]

let%expect_test "resolve: one tag matches ticket pattern (no config)" =
  let config = Config.empty in
  let tags = [
    { Watson.name = "DEV-101"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
    { Watson.name = "review"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
  ] in
  let result = resolve_entry_mapping ~config ~project:"cr" ~tags in
  print_s [%sexp (result : entry_resolution)];
  [%expect {| (Tag_inferred DEV-101) |}]

let%expect_test "resolve: two tags with composite mappings -> auto-split" =
  let config = { Config.empty with mappings = [
    ("cr:DEV-101", Config.Ticket "DEV-101");
    ("cr:DEV-202", Config.Ticket "DEV-202");
  ] } in
  let tags = [
    { Watson.name = "DEV-101"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
    { Watson.name = "DEV-202"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
  ] in
  let result = resolve_entry_mapping ~config ~project:"cr" ~tags in
  print_s [%sexp (result : entry_resolution)];
  [%expect {| Auto_split |}]

let%expect_test "resolve: one composite + one ticket pattern -> auto-split" =
  let config = { Config.empty with mappings = [("cr:DEV-101", Config.Ticket "DEV-101")] } in
  let tags = [
    { Watson.name = "DEV-101"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
    { Watson.name = "DEV-202"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
  ] in
  let result = resolve_entry_mapping ~config ~project:"cr" ~tags in
  print_s [%sexp (result : entry_resolution)];
  [%expect {| Auto_split |}]

let%expect_test "resolve: no mappings at all" =
  let config = Config.empty in
  let tags = [
    { Watson.name = "review"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
  ] in
  let result = resolve_entry_mapping ~config ~project:"cr" ~tags in
  print_s [%sexp (result : entry_resolution)];
  [%expect {| Uncached |}]

let%expect_test "resolve: no tags" =
  let config = Config.empty in
  let result = resolve_entry_mapping ~config ~project:"cr" ~tags:[] in
  print_s [%sexp (result : entry_resolution)];
  [%expect {| Uncached |}]

let%expect_test "resolve: project mapping takes precedence over tag mappings" =
  let config = { Config.empty with mappings = [
    ("cr", Config.Ticket "PROJ-1");
    ("cr:DEV-101", Config.Ticket "DEV-101");
    ("cr:DEV-202", Config.Ticket "DEV-202");
  ] } in
  let tags = [
    { Watson.name = "DEV-101"; duration = Duration.of_hms ~hours:0 ~mins:30 ~secs:0 };
    { Watson.name = "DEV-202"; duration = Duration.of_hms ~hours:0 ~mins:15 ~secs:0 };
  ] in
  let result = resolve_entry_mapping ~config ~project:"cr" ~tags in
  print_s [%sexp (result : entry_resolution)];
  [%expect {| (Project_cached PROJ-1) |}]

let%expect_test "process_entry split with mixed tags" =
  let entry = {
    Watson.project = "cr";
    total = Duration.of_hms ~hours:1 ~mins:0 ~secs:0;
    tags = [
      { Watson.name = "DEV-101"; duration = Duration.of_hms ~hours:0 ~mins:35 ~secs:0 };
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
  [%expect {| ((Post (ticket DEV-101) (duration 2100) (source cr:DEV-101) (description ""))) |}];
  (* No entry-level mapping for splits *)
  print_s [%sexp (mapping : Config.mapping option)];
  [%expect {| () |}]
