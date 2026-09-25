; Codec-valid graphs are not necessarily semantically valid projects.
((format ((major 2) (minor 0))) (name "cycles")
 (systems ("x86_64-linux"))
 (environments (
   ((name "a") (parents ("b")) (tools ()) (overlays ()))
   ((name "b") (parents ("a")) (tools ()) (overlays ()))
   ((name "self") (parents ("self")) (tools ()) (overlays ()))))
 (shells (((name "default") (environment "a")))))
