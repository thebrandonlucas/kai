import kai.Plugin
import backends.Nix as NixBackend
import commands.Update as UpdateCommand
UpdateNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [NixBackend.flake_template].concat(NixBackend.update_lock_templates),
		backend: NixBackend.backend.name,
		command: UpdateCommand.command.name,
		renderer: |_| Ok(
			Plugin.RenderResult.{
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
