; Parent-first tools retain source identity and deduplicate first occurrences.
((format ((major 2) (minor 0))) (name "inheritance")
 (systems ("x86_64-linux"))
 (sources (((name "default") (provider Auto))
   ((name "stable") (provider (NixPackages "github:NixOS/nixpkgs/nixos-24.05")))))
 (environments (
   ((name "base") (parents ()) (overlays ())
    (tools (((source "default") (name "git")))))
   ((name "dev") (parents ("base")) (overlays ())
    (tools (((source "default") (name "git"))
      ((source "stable") (name "python3")))))
   ((name "ci") (parents ("dev")) (tools ()) (overlays ()))))
 (shells (((name "default") (environment "dev"))))
 (tasks (((name "version") (environment "ci") (run ("git" "--version"))))))
