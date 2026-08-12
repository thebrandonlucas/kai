import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Update as UpdateCommand
UpdateNix := [].{
	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: [
			WriteConfigUtf8({ output: "flake", path: ".kai/flake.nix" }),
			Exec({
				args: [
					"flake",
					"update",
					"--flake",
					"path:.kai",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					"kai.lock",
				],
				command: NixBackend.backend.name,
			}),
			Exec({
				args: [
					"flake",
					"lock",
					"path:.kai",
					"--reference-lock-file",
					"kai.lock",
					"--output-lock-file",
					".kai/flake.lock",
				],
				command: NixBackend.backend.name,
			}),
		],
		backend: NixBackend.backend.name,
		command: UpdateCommand.command.name,
		renderer: |_| Ok(
			PluginApi.RenderResult.{
				actions: [],
				outputs: [{ name: "flake", text: UpdateNix.flake }],
				requested_packages: [],
			},
		),
	}

	flake : Str
	flake = "{\n  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";\n  outputs = _: {};\n}"
}
