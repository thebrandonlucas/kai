; Legacy shell-owned packages and task In(shell) must remain rejected.
((format ((major 1) (minor 0))) (name "legacy")
 (inputs (((kind Packages) (name "nixpkgs") (url "github:NixOS/nixpkgs"))))
 (shells (((name "default")
   (packages (((source "nixpkgs") (path ("git"))))))))
 (tasks (((name "test") (shell "default") (run ("git" "--version"))))))
