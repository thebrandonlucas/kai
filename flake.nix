{
  description = "Kai development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Intel macOS is no longer supported by nixos-unstable.
    nixpkgs-x86-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    # Keep the Roc compiler compatible with basic-cli 0.21.0-rc4.
    roc-overlay = {
      url = "github:thebrandonlucas/roc-overlay/a9afdcfed9bf90c53e6b4b1443e00676a939e971";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-darwin.follows = "nixpkgs-x86-darwin";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-x86-darwin,
      roc-overlay,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor =
        system:
        import (if system == "x86_64-darwin" then nixpkgs-x86-darwin else nixpkgs) {
          inherit system;
          overlays = [ roc-overlay.overlays.default ];
        };
    in
    {
      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.rocpkgs.nightly
              pkgs.zig_0_16
              pkgs.diffutils
            ];
          };
        }
      );
    };
}
