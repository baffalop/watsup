open Core

type cached_response = Keep | Change_ticket | Change_category | Skip_once | Split

let cached_entry ~creds ~ticket ~has_tags =
  match Jira_search.lookup_cached_ticket ~creds ~ticket with
  | Found result ->
    Io.styled @@ sprintf "  {action}[-> %s \"%s\"]{/}\n" result.key result.summary;
    let split_opt = if has_tags then " | [s] split" else "" in
    Io.styled @@ sprintf "  {prompt}[Enter] keep | [t] ticket%s | [c] category | [n] skip:{/} " split_opt;
    (match Io.input () with
     | "t" -> (Change_ticket, true)
     | "s" when has_tags -> (Split, true)
     | "c" -> (Change_category, true)
     | "n" -> (Skip_once, true)
     | _ -> (Keep, true))
  | Not_found _msg ->
    (Change_ticket, false)

let cached_skip () =
  Io.styled "  {action}[skip]{/}\n";
  Io.styled "  {prompt}[Enter] keep | [t] assign ticket:{/} ";
  match Io.input () with
  | "t" -> Change_ticket
  | _ -> Keep

let uncached_entry ~creds ~starred_projects ~date entry =
  Io.output "\n";
  let has_tags = not (List.is_empty entry.Watson.tags) in
  let search_hint =
    let tag_names = List.map entry.Watson.tags ~f:(fun t -> t.Watson.name) in
    String.concat ~sep:" " (entry.Watson.project :: tag_names)
  in
  match Jira_search.prompt_loop ~creds ~search_hint ~has_tags
      ~starred_projects ~log_date:date with
  | Jira_search.Selected result -> Processor.Accept result.key
  | Jira_search.Skip_once -> Processor.Skip_once
  | Jira_search.Skip_always -> Processor.Skip_always
  | Jira_search.Split -> Processor.Split

let uncached_tag ~creds ~starred_projects ~date ~project tag =
  Io.styled @@ sprintf "  [{tag}%-8s{/} {duration}%s{/}] " tag.Watson.name
    (Duration.to_string @@ Duration.round_5min tag.Watson.duration);
  let search_hint = sprintf "%s %s" project tag.Watson.name in
  match Jira_search.prompt_loop ~creds ~search_hint ~has_tags:false
      ~starred_projects ~log_date:date with
  | Jira_search.Selected result -> Processor.Tag_accept result.key
  | Jira_search.Skip_once | Jira_search.Skip_always -> Processor.Tag_skip
  | Jira_search.Split -> Processor.Tag_skip

let cached_tag ~creds tag ~ticket =
  Io.styled @@ sprintf "  [{tag}%-8s{/} {duration}%s{/}] " tag.Watson.name
    (Duration.to_string @@ Duration.round_5min tag.Watson.duration);
  match Jira_search.lookup_cached_ticket ~creds ~ticket with
  | Found result ->
    Io.styled @@ sprintf "{action}[-> %s \"%s\"]{/} {prompt}[Enter] keep | [t] change | [n] skip:{/} "
      result.key result.summary;
    (match Io.input () with
     | "t" -> (Change_ticket, true)
     | "n" -> (Skip_once, true)
     | _ -> (Keep, true))
  | Not_found _msg ->
    (Change_ticket, false)

let description ticket =
  Io.output @@ sprintf "  Description for %s (optional): " ticket;
  Io.input ()

let category_list ~options ~current_value =
  List.iteri options ~f:(fun i cat ->
    let marker = match current_value with
      | Some v when String.equal v (Category.value cat) -> " *"
      | _ -> ""
    in
    Io.output @@ sprintf "    %d. %s%s\n" (i + 1) (Category.name cat) marker);
  Io.output "  > ";
  let input = Io.input () in
  match Int.of_string_opt input with
  | Some n when n >= 1 && n <= List.length options ->
    Category.value (List.nth_exn options (n - 1))
  | _ ->
    Category.value (List.hd_exn options)

let category ~config ~options ticket =
  match Config.get_category_selection config ticket with
  | Some cached_value ->
    (match List.find options ~f:(fun cat -> String.equal (Category.value cat) cached_value) with
     | Some cat ->
       Io.styled @@ sprintf "  %s category: %s\n    {prompt}[Enter] keep | [c] change:{/} " ticket (Category.name cat);
       let input = Io.input () in
       if String.equal input "c" then begin
         let value = category_list ~options ~current_value:(Some cached_value) in
         Config.set_category_selection config ticket value
       end else
         config
     | None ->
       Io.output @@ sprintf "  %s category (previous selection no longer available):\n" ticket;
       let value = category_list ~options ~current_value:None in
       Config.set_category_selection config ticket value)
  | None ->
    Io.output @@ sprintf "  %s category:\n" ticket;
    let value = category_list ~options ~current_value:None in
    Config.set_category_selection config ticket value
