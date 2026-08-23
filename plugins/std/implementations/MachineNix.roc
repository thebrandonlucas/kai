import parser.Body
import kai.Plugin
import backends.Nix as NixBackend
import commands.Machine as MachineCommand
import EnvironmentNix

MachineNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [],
		backend: NixBackend.backend.name,
		command: MachineCommand.command.name,
		renderer: MachineNix.renderer,
		validator: NoValidation,
	}

	MachineMetadata := {
		backend : Str,
		closure_path : Str,
		flake_attribute : Str,
		flake_path : Str,
		metadata_path : Str,
		name : Str,
		target_architecture : Str,
		target_system : Str,
	}

	Configuration := {
		locked_overlays : List(Str),
		name : Str,
		overlays : List(Str),
		pkgs : List(Str),
		services : List(Str),
		target_architecture : Str,
		target_system : Str,
		users : List(Str),
	}

	configuration : Plugin.RenderContext, Str -> Try(Configuration, Plugin.RendererDiagnostic)
	configuration = |context, command_name| {
		name = match context.args {
			[selected_name] => Ok(selected_name)
			[] => Ok(NixBackend.backend.name)
			_ => Err({ byte_offset: None, message: "${command_name} requires exactly one name" })
		}?
		environment = match context.related_config {
			NoRelatedConfig => Err({ byte_offset: None, message: "machine environment is required" })
			SelectedRelatedConfig({ block: _, config }) => Ok(config)
		}?
		pkgs = Body.get_strings(environment, "packages") ? |_|
			{ byte_offset: None, message: "validated machine environment is missing 'packages'" }
		overlays = EnvironmentNix.extract_overlays(environment)?
		locked_overlays = EnvironmentNix.all_overlays(context)?
		system = Body.get_string(context.config, "system") ? |_|
			{ byte_offset: None, message: "validated machine configuration is missing 'system'" }
		users = MachineNix.optional_strings(context.config, "users")?
		services = MachineNix.optional_strings(context.config, "services")?
		failures = Plugin.validate_text(name, MachineCommand.name_rules)
			.concat(Plugin.validate_string_list(pkgs, NixBackend.package_rules))
			.concat(MachineCommand.user_failures(users))
			.concat(MachineCommand.service_failures(services))
		Plugin.renderer_validation(failures)?
		target = NixBackend.machine_target(system, context.host_os, context.host_arch) ? |problem|
			match problem {
				UnsupportedMachineSystem => {
					byte_offset: None,
					message: "unsupported NixOS machine system '${system}'; expected 'x86_64-linux' or 'aarch64-linux'",
				}
				UnsupportedMachineHost => {
					byte_offset: None,
					message: "NixOS machine builds are supported only on Linux hosts",
				}
				CrossArchitectureMachine => {
					byte_offset: None,
					message: "cross-architecture NixOS machine builds are not supported; target '${system}' must match the host architecture",
				}
			}
		Ok(
			MachineNix.Configuration.{
				locked_overlays,
				name,
				overlays,
				pkgs,
				services,
				target_architecture: target.architecture,
				target_system: target.system,
				users,
			},
		)
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		config = MachineNix.configuration(context, "machine")?
		machine_metadata = MachineNix.MachineMetadata.{
			backend: NixBackend.backend.name,
			closure_path: NixBackend.machine_closure_path(config.name),
			flake_attribute: "kaiMachines.\"${config.name}\".closure",
			flake_path: NixBackend.machine_flake_path(config.name),
			metadata_path: NixBackend.machine_metadata_path(config.name),
			name: config.name,
			target_architecture: config.target_architecture,
			target_system: config.target_system,
		}
		flake = MachineNix.render_flake(config.name, config.target_system, config.locked_overlays, config.overlays)
		module_text = MachineNix.render_module(config.pkgs, config.users, config.services)
		metadata = MachineNix.render_metadata(machine_metadata)
		Ok(
			Plugin.RenderResult.{
				actions: NixBackend.machine_actions(config.name, flake, module_text, metadata),
				artifacts: [
					{
						attributes: [
							{ key: "backend", value: NixBackend.backend.name },
							{ key: "target.architecture", value: config.target_architecture },
							{ key: "target.system", value: config.target_system },
						],
						kind: "kai.machine.closure/v1",
						name: config.name,
						path: NixBackend.machine_closure_path(config.name),
					},
				],
				outputs: [],
				requests: [],
				requested_packages: config.pkgs,
			},
		)
	}

	optional_strings : Body.Configuration, Str -> Try(List(Str), Plugin.RendererDiagnostic)
	optional_strings = |config, field|
		match Body.maybe_strings(config, field) {
			Ok(None) => Ok([])
			Ok(Some(values)) => Ok(values)
			Err(_) => Err({ byte_offset: None, message: "validated machine configuration has invalid '${field}'" })
		}

	render_metadata : MachineMetadata -> Str
	render_metadata = |metadata| {
		schema : U64
		schema = 1
		Json.to_str({
			backend: metadata.backend,
			closure_path: metadata.closure_path,
			flake_attribute: metadata.flake_attribute,
			flake_path: metadata.flake_path,
			kind: "machine",
			metadata_path: metadata.metadata_path,
			name: metadata.name,
			schema,
			target_architecture: metadata.target_architecture,
			target_system: metadata.target_system,
		})
	}

	render_flake : Str, Str, List(Str), List(Str) -> Str
	render_flake = |name, system, locked_overlays, overlays| {
		overlay_names = locked_overlays.map_with_index(|_, index| "overlay${U64.to_str(index)}")
		overlay_lines = overlays.map(|overlay| "          ${NixBackend.overlay_name(locked_overlays, overlay, 0)}.overlays.default")
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
			"        modules = [ { nixpkgs.pkgs = pkgs; } ./machine.nix ];",
			"      };",
			"    in {",
			"      nixosConfigurations.\"${name}\" = machine;",
			"      kaiMachines.\"${name}\" = {",
			"        kind = \"machine\";",
			"        name = \"${name}\";",
			"        inherit system;",
			"        closure = machine.config.system.build.toplevel;",
			"      };",
			"    };",
			"}",
		])
		Str.join_with(lines, "\n")
	}

	render_module : List(Str), List(Str), List(Str) -> Str
	render_module = |pkgs, users, services| {
		package_lines = pkgs.map(|pkg| "    pkgs.${NixBackend.render_attributes(pkg)}")
		user_lines = users.map(|user| "  users.users.\"${user}\".isNormalUser = true;")
		service_lines = services.map(|service| "  services.${NixBackend.render_attributes(service)}.enable = true;")
		lines = [
			"{ pkgs, ... }:",
			"{",
			"  boot.loader.grub.enable = false;",
			"  fileSystems.\"/\" = {",
			"    device = \"/dev/root\";",
			"    fsType = \"auto\";",
			"  };",
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
