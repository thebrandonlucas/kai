{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllLinux = nixpkgs.lib.genAttrs linuxSystems;
    in {
      devShells = forAllLinux (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.guix ];
          };
        });
    };
}
