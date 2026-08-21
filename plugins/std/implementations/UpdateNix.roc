import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Update as UpdateCommand
UpdateNix := [].{
	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: NixBackend.update_recipe,
		backend: NixBackend.backend.name,
		command: UpdateCommand.command.name,
		renderer: |_| Ok(
			PluginApi.RenderResult.{
				actions: [],
				outputs: [{ name: "flake", text: UpdateNix.flake }],
				requests: [],
				requested_packages: [],
			},
		),
	}

	flake : Str
	flake = "{\n  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";\n  outputs = _: {};\n}"
}
