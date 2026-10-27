# An overlay adds or changes packages. This one adds `moo`, a cowsay that
# always moos, built on the cowsay the package source already has. Like many
# overlays it declares its own nixpkgs, which the Kaifile's Follows replaces
# with the project's.
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    {
      overlays.default = final: prev: {
        moo = prev.writeShellScriptBin "moo" ''
          exec ${prev.cowsay}/bin/cowsay moo "$@"
        '';
      };
    };
}
