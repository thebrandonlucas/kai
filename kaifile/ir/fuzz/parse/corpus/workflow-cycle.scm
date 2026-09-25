((format ((major 2) (minor 2)))
 (name "unused-cycle") (requires ("workflows")) (systems ("x86_64-linux"))
 (workflows (
   ((name "safe") (steps ()))
   ((name "a") (steps ((RunWorkflow "b"))))
   ((name "b") (steps ((RunWorkflow "a")))))))
