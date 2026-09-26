((format ((major 2) (minor 2)))
 (name "empty-diamond") (requires ("workflows")) (systems ("x86_64-linux"))
 (workflows (
   ((name "root") (steps ((RunWorkflow "left") (RunWorkflow "right"))))
   ((name "left") (steps ((RunWorkflow "empty") (RunWorkflow "empty"))))
   ((name "right") (steps ((RunWorkflow "empty") (RunWorkflow "empty"))))
   ((name "empty") (steps ())))))
