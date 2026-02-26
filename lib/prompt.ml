open Core

type action =
  | Accept of string
  | Skip
  | Skip_always
  | Split
  | Set_message of string
  | Change_category
  | Quit
[@@deriving sexp]

let read_line_safe () =
  match In_channel.(input_line stdin) with
  | Some line -> line
  | None -> ""

let prompt_entry entry ~cached ~category =
  let open Watson in
  printf "\n%s - %s\n" entry.project
    (Duration.to_string (Duration.round_5min entry.total));
  (match cached with
   | Some (Config.Ticket t) -> printf "  Cached: %s\n" t
   | Some Config.Skip -> printf "  Cached: SKIP\n"
   | Some Config.Auto_extract -> printf "  Auto-extract mode\n"
   | None -> ());
  printf
    "  [Enter] accept | [ticket] override | [s]plit | [n]skip | [S]kip always\n";
  printf "  [m]essage | [c]ategory (current: %s) | [q]uit\n" category;
  printf "> %!";
  let input = read_line_safe () in
  match input with
  | "" -> (
    match cached with
    | Some (Config.Ticket t) -> Accept t
    | _ -> Skip)
  | "s" -> Split
  | "n" -> Skip
  | "S" -> Skip_always
  | "c" -> Change_category
  | "q" -> Quit
  | s when String.is_prefix s ~prefix:"m " ->
    Set_message (String.chop_prefix_exn s ~prefix:"m ")
  | ticket -> Accept ticket

let prompt_tag ~project tag =
  let open Watson in
  printf "\n%s [%s] - %s\n" project tag.name
    (Duration.to_string (Duration.round_5min tag.duration));
  printf "  [ticket] assign | [n]skip | [q]uit split\n";
  printf "> %!";
  let input = read_line_safe () in
  match input with
  | "n" -> Skip
  | "q" -> Quit
  | "" -> Skip
  | ticket -> Accept ticket

let prompt_ticket ~default =
  (match default with
   | Some t -> printf "Ticket [%s]: %!" t
   | None -> printf "Ticket: %!");
  let input = read_line_safe () in
  match (input, default) with
  | "", Some t -> t
  | "", None -> ""
  | s, _ -> s

let prompt_confirm_post worklogs ~skipped ~manual =
  printf "\n=== Worklogs to Post ===\n";
  List.iter worklogs ~f:(fun w ->
      printf "%-12s %-15s %8s  %s\n" w.Worklog.ticket w.source
        (Duration.to_string w.duration)
        (Category.name w.category));
  let total =
    List.fold worklogs ~init:Duration.zero ~f:(fun acc w ->
        Duration.(acc + w.Worklog.duration))
  in
  printf "                        ------\n";
  printf "Total:                  %8s  (target: 7h 30m)\n"
    (Duration.to_string total);
  if not (List.is_empty skipped) then begin
    printf "\n=== Skipped (cached) ===\n";
    List.iter skipped ~f:(fun (name, dur) ->
        printf "%-28s %8s\n" name (Duration.to_string dur))
  end;
  if not (List.is_empty manual) then begin
    printf "\n=== Manual Required (no Account) ===\n";
    List.iter manual ~f:(fun (name, dur) ->
        printf "%-28s %8s  [no account found]\n" name (Duration.to_string dur))
  end;
  printf "\n[Enter] post all | [q]uit without posting\n";
  printf "> %!";
  let input = read_line_safe () in
  not (String.equal input "q")

let prompt_token () =
  printf "Enter Tempo API token: %!";
  read_line_safe ()

let prompt_category (categories : Category.t list) ~current =
  printf "\nSelect category:\n";
  List.iteri categories ~f:(fun i c ->
    let category_name = Category.name c in
    let marker =
      match current with
      | Some cur when String.(cur = category_name) -> " *"
      | _ -> ""
    in
    printf "  %d. %s%s\n" (i + 1) category_name marker);
  printf "  [r] refresh from API\n";
  printf "> %!";
  let input = read_line_safe () in
  match Int.of_string_opt input with
  | Some n when n > 0 && n <= List.length categories ->
    Category.name @@ List.nth_exn categories (n - 1)
  | _ -> (
    match current with
    | Some c -> c
    | None -> "Development")
