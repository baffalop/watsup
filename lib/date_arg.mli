open! Core

(** Parse a CLI date argument relative to [today]. Accepts:
    - [YYYY-MM-DD]
    - [MM-DD]: current year, or previous year if that would be in the future
    - [DD]: current month, or previous month if that would be in the future
    - [0]: today
    - [-N]: N days ago *)
val parse : today:Date.t -> string -> Date.t Or_error.t

(** Resolve [--day] / [--from] / [--to] into the list of dates to process.
    No arguments means today; [--from] without [--to] runs through today. *)
val resolve :
  today:Date.t ->
  day:string option ->
  from_date:string option ->
  to_date:string option ->
  Date.t list Or_error.t
