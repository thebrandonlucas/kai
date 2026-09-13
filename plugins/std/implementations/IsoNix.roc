# An implementation for building bootable machine ISOs with Nix.
import kai.Plugin
import backends.Nix as NixBackend
import commands.Iso as IsoCommand
import MachineNix

IsoNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: IsoCommand.command_syntax.name,
		plan: IsoNix.plan,
		validator: NoValidation,
	}

	iso_output_path : Str, Str -> Str
	iso_output_path = |workspace_root, name|
		Plugin.workspace_path(workspace_root, "artifacts/isos/${name}/result")

	iso_file_path : Str, Str -> Str
	iso_file_path = |workspace_root, name|
		"${IsoNix.iso_output_path(workspace_root, name)}/iso/${name}.iso"

	iso_flake_path : Str, Str -> Str
	iso_flake_path = |workspace_root, name|
		Plugin.workspace_path(workspace_root, "isos/${name}")

	iso_steps :
		Str, Str, Str, Str, List(Plugin.Artifact) -> List(Plugin.ExecutionStep)
	iso_steps = |workspace_root, name, flake, module_text, services| {
		flake_path = IsoNix.iso_flake_path(workspace_root, name)
		[
			WriteFile({ contents: flake, path: "${flake_path}/flake.nix" }),
			WriteFile({ contents: module_text, path: "${flake_path}/machine.nix" }),
		]
			.concat(MachineNix.service_copy_steps(flake_path, services))
			.concat(NixBackend.lock_steps(flake_path))
			.concat([
				WriteFile({
					contents: "",
					path: Plugin.workspace_path(
						workspace_root,
						"artifacts/isos/${name}/.keep",
					),
				}),
				NixBackend.run([
					"build",
					"path:${flake_path}#kaiIsos.\"${name}\"",
					"--no-update-lock-file",
					"--out-link",
					IsoNix.iso_output_path(workspace_root, name),
				]),
			])
	}

	plan :
		Plugin.CommandPlanningInput ->
			Try(
				Plugin.BackendCommandPlan,
				Plugin.BackendPlanningDiagnostic,
			)
	plan = |input| {
		spec = MachineNix.machine_spec(input, "iso")?
		prerequisite_commands = MachineNix.service_prerequisite_commands(
			spec.generated_services,
			"iso",
		)
		services = match input.prerequisite_artifacts {
			NotResolved =>
				if prerequisite_commands.is_empty() {
					Ok([])
				} else {
					return Ok({
						artifacts: [],
						prerequisite_commands,
						requested_packages: spec.pkgs,
						steps: [],
					})
				}
			Resolved(artifacts) =>
				MachineNix.resolve_services(
					artifacts,
					spec.generated_services,
					spec.target_system,
				)
			}?
		native_services = spec.services.keep_if(|service|
			!spec.generated_services.contains(service))
		Ok(
			Plugin.BackendCommandPlan.{
				artifacts: [
					{
						attributes: [{ key: "format", value: "iso" }],
						kind: "kai.machine.iso/v1",
						name: spec.name,
						path: IsoNix.iso_file_path(
							input.workspace_root,
							spec.name,
						),
					},
				],
				prerequisite_commands,
				requested_packages: spec.pkgs,
				steps: IsoNix.iso_steps(
					input.workspace_root,
					spec.name,
					IsoNix.render_flake(
						spec.name,
						spec.target_system,
						spec.locked_overlays,
						spec.overlays,
						services,
					),
					NixBackend.render_nixos_module(
						spec.pkgs,
						spec.users,
						native_services,
					),
					services,
				),
			},
		)
	}

	render_flake : Str, Str, List(Str), List(Str), List(Plugin.Artifact) -> Str
	render_flake = |name, system, locked_overlays, overlays, services| {
		overlay_lines = overlays.map(
			|overlay|
				"          ${NixBackend.overlay_expression(locked_overlays, overlay, 0)}",
		)
		outputs_args = NixBackend.overlay_outputs_args(locked_overlays)
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
		].concat(NixBackend.input_lines(locked_overlays)).concat([
			"  outputs = { ${outputs_args}, ... }:",
			"    let",
			"      system = \"${system}\";",
			"      pkgs = import nixpkgs {",
			"        inherit system;",
			"        overlays = [",
		]).concat(overlay_lines).concat([
			"        ];",
			"      };",
			"      machine = nixpkgs.lib.nixosSystem {",
			"        inherit system;",
			"        modules = [",
			"          { nixpkgs.pkgs = pkgs; }",
			"          ({ lib, modulesPath, ... }: {",
			"            imports = [",
			"              (modulesPath + \"/installer/cd-dvd/\"",
			"                + \"installation-cd-minimal.nix\")",
			"            ];",
			"            image.baseName = lib.mkForce \"${name}\";",
			"          })",
			"          ./machine.nix",
		]).concat(MachineNix.service_module_lines(services)).concat([
			"        ];",
			"      };",
			"    in {",
			"      nixosConfigurations.\"${name}\" = machine;",
			"      kaiIsos.\"${name}\" = machine.config.system.build.isoImage;",
			"    };",
			"}",
		])
		Str.join_with(lines, "\n")
	}
}
