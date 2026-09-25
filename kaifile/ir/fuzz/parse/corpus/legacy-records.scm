; Major 2 must not reinterpret the old nested records as environments.
((format ((major 2) (minor 0))) (name "old-records")
 (inputs (((kind Packages) (name "nixpkgs") (url "github:NixOS/nixpkgs"))))
 (shells (((name "default") (packages ())))))
