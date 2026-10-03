# Replaces fixtureTool, discarding any earlier overlay's version.
{
  outputs =
    { self }:
    {
      overlays.default = final: prev: {
        fixtureTool = prev.writeShellScriptBin "fixture-tool" "echo base";
      };
    };
}
