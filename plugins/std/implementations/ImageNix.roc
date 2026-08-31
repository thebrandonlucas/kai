# An implementation for building machine images with nix.
import kai.Plugin
import backends.Nix as NixBackend
import schemas.Image as ImageCommand
import MachineNix

ImageNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: ImageCommand.command_syntax.name,
		plan: ImageNix.plan,
		validator: NoValidation,
	}

	plan :
		Plugin.ImplementationInput ->
			Try(
				Plugin.CommandPlan,
				Plugin.ImplementationDiagnostic,
			)
	plan = |input| {
		spec = MachineNix.machine_spec(input, "image")?
		prerequisite_commands = MachineNix.service_prerequisite_commands(
			spec.generated_services,
			"image",
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
		schema : U64
		schema = 1
		metadata = Json.to_str({
			backend: NixBackend.backend.name,
			flake_attribute: "kaiImages.\"${spec.name}\".image",
			flake_path: NixBackend.image_flake_path(spec.name),
			format: "qcow2",
			kind: "machine-image",
			metadata_path: NixBackend.image_metadata_path(spec.name),
			name: spec.name,
			output_path: NixBackend.image_file_path(spec.name),
			schema,
			target_architecture: spec.target_architecture,
			target_system: spec.target_system,
		})
		Ok(
			Plugin.CommandPlan.{
				artifacts: [
					{
						attributes: [
							{ key: "backend", value: NixBackend.backend.name },
							{ key: "format", value: "qcow2" },
							{ key: "target.architecture", value: spec.target_architecture },
							{ key: "target.system", value: spec.target_system },
						],
						kind: "kai.machine.image/v1",
						name: spec.name,
						path: NixBackend.image_file_path(spec.name),
					},
				],
				prerequisite_commands,
				requested_packages: spec.pkgs,
				steps: NixBackend.image_steps(
					spec.name,
					ImageNix.render_flake(
						spec.name,
						spec.target_system,
						spec.locked_overlays,
						spec.overlays,
						services,
					),
					ImageNix.render_module(
						spec.pkgs,
						spec.users,
						native_services,
					),
					metadata,
					services,
				),
			},
		)
	}

	render_flake : Str, Str, List(Str), List(Str), List(Plugin.Artifact) -> Str
	render_flake = |name, system, locked_overlays, overlays, services| {
		overlay_names = locked_overlays.map_with_index(|_, index|
			"overlay${U64.to_str(index)}")
		overlay_lines = overlays.map(
			|overlay|
				Str.join_with(
					[
						"          ",
						NixBackend.overlay_name(locked_overlays, overlay, 0),
						".overlays.default",
					],
					"",
				),
		)
		outputs_args = Str.join_with(["nixpkgs"].concat(overlay_names), ", ")
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
			"          ({ modulesPath, ... }: {",
			"            imports = [",
			"              (modulesPath + \"/profiles/qemu-guest.nix\")",
			"              (modulesPath + \"/virtualisation/disk-image.nix\")",
			"            ];",
			"            image.baseName = \"${name}\";",
			"          })",
			"          ./machine.nix",
		]).concat(MachineNix.service_module_lines(services)).concat([
			"        ];",
			"      };",
			"    in {",
			"      nixosConfigurations.\"${name}\" = machine;",
			"      kaiImages.\"${name}\" = {",
			"        kind = \"machine-image\";",
			"        name = \"${name}\";",
			"        format = \"qcow2\";",
			"        inherit system;",
			"        image = machine.config.system.build.image;",
			"      };",
			"    };",
			"}",
		])
		Str.join_with(lines, "\n")
	}

	render_module : List(Str), List(Str), List(Str) -> Str
	render_module = |pkgs, users, services| {
		package_lines = pkgs.map(|pkg|
			"    pkgs.${NixBackend.render_attributes(pkg)}")
		user_lines = users.map(|user|
			"  users.users.\"${user}\".isNormalUser = true;")
		service_lines = services.map(
			|service|
				Str.join_with(
					[
						"  services.",
						NixBackend.render_attributes(service),
						".enable = true;",
					],
					"",
				),
		)
		lines = [
			"{ pkgs, ... }:",
			"{",
			"  system.stateVersion = \"25.05\";",
			"  environment.systemPackages = [",
		].concat(package_lines).concat([
			"  ];",
		]).concat(user_lines).concat(service_lines).concat([
			"}",
		])
		Str.join_with(lines, "\n")
	}
}
