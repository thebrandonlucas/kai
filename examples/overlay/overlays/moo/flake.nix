# An overlay adds or changes packages. This one adds `moo`, a cowsay that
# always moos, built on the cowsay the package source already has.
{
  outputs =
    { self }:
    {
      overlays.default = final: prev: {
        moo = prev.writeShellScriptBin "moo" ''
          exec ${prev.cowsay}/bin/cowsay moo "$@"
        '';
      };
    };
}
