# An implementation for building machine images with nix.
import kai.Plugin
import backends.Nix as NixBackend
import commands.Image as ImageCommand
import MachineNix

ImageNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [],
		backend: NixBackend.backend.name,
		command: ImageCommand.command.name,
		renderer: ImageNix.renderer,
		validator: NoValidation,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		config = MachineNix.configuration(context, "image")?
		requests = MachineNix.service_requests(config.generated_services, "image")
		if !requests.is_empty() and !context.dependencies_resolved {
			return Ok({
				actions: [],
				artifacts: [],
				outputs: [],
				requests,
				requested_packages: config.pkgs,
			})
		}
		services = MachineNix.resolve_services(
			context.dependency_artifacts,
			config.generated_services,
			config.target_system,
		)?
		native_services = config.services.keep_if(|service|
			!config.generated_services.contains(service))
		schema : U64
		schema = 1
		metadata = Json.to_str({
			backend: NixBackend.backend.name,
			flake_attribute: "kaiImages.\"${config.name}\".image",
			flake_path: NixBackend.image_flake_path(config.name),
			format: "qcow2",
			kind: "machine-image",
			metadata_path: NixBackend.image_metadata_path(config.name),
			name: config.name,
			output_path: NixBackend.image_file_path(config.name),
			schema,
			target_architecture: config.target_architecture,
			target_system: config.target_system,
		})
		Ok(
			Plugin.RenderResult.{
				actions: NixBackend.image_actions(
					config.name,
					ImageNix.render_flake(
						config.name,
						config.target_system,
						config.locked_overlays,
						config.overlays,
						services,
					),
					ImageNix.render_module(
						config.pkgs,
						config.users,
						native_services,
					),
					metadata,
					services,
				),
				artifacts: [
					{
						attributes: [
							{ key: "backend", value: NixBackend.backend.name },
							{ key: "format", value: "qcow2" },
							{ key: "target.architecture", value: config.target_architecture },
							{ key: "target.system", value: config.target_system },
						],
						kind: "kai.machine.image/v1",
						name: config.name,
						path: NixBackend.image_file_path(config.name),
					},
				],
				outputs: [],
				requests,
				requested_packages: config.pkgs,
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
