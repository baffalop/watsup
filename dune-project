(lang dune 3.16)
(name watsup)

(generate_opam_files true)

(package
 (name watsup)
 (synopsis "Watson to Jira Tempo CLI")
 (depends
  (ocaml (>= 5.4.0))
  (core (>= 0.17))
  (core_unix (>= 0.17))
  (angstrom (>= 0.16))
  (cohttp-lwt-unix (>= 6.0))
  (lwt (>= 5.7))
  (yojson (>= 2.1))
  (ppx_jane (>= 0.17))
  (ppx_expect (>= 0.17))
  (ppx_inline_test (>= 0.17))
  (re (>= 1.11))))
