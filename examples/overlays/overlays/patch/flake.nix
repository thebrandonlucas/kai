# Modifies the fixtureTool an earlier overlay supplied.
{
  outputs =
    { self }:
    {
      overlays.default = final: prev: {
        fixtureTool = prev.writeShellScriptBin "fixture-tool" ''
          printf 'patch:'
          exec ${prev.fixtureTool}/bin/fixture-tool "$@"
        '';
      };
    };
}
