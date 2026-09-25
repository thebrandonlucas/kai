((format ((major 2) (minor 2)))
 (name "workflow-graph")
 (requires ("builds" "workflows"))
 (systems ("x86_64-linux"))
 (environments (((name "dev") (parents ()) (tools ()) (overlays ()))))
 (tasks (((name "check.all") (environment "dev") (run ("true")))))
 (builds (((name "app") (environment "dev") (inputs ()) (needs ())
   (run ("true")) (output "out"))))
 (workflows (
   ((name "ci") (steps ((RunWorkflow "leaf") (BuildArtifact "app")
     (RunWorkflow "leaf") (BuildArtifact "app"))))
   ((name "leaf") (steps ((RunTask "check.all"
     ("" "two words" "\"quoted\"" "$HOME" "line\nbreak" "--flag"))))))))
