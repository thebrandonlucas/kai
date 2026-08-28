# Implements NixOS machine builds and service module integration.
import parser.Fields
import kai.Plugin
import backends.Nix as NixBackend
import commands.Machine as MachineCommand
import configs.MachineConfig
import EnvironmentNix

MachineNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [],
		backend: NixBackend.backend.name,
		command: MachineCommand.command.call.name,
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
		generated_services : List(Str),
		locked_overlays : List(Str),
		name : Str,
		overlays : List(Str),
		pkgs : List(Str),
		services : List(Str),
		target_architecture : Str,
		target_system : Str,
		users : List(Str),
	}

	configuration :
		Plugin.RenderContext, Str -> Try(Configuration, Plugin.RendererDiagnostic)
	configuration = |context, command_name| {
		name = match context.args {
			[selected_name] => Ok(selected_name)
			_ => Err({
				byte_offset: None,
				message: "${command_name} requires exactly one name",
			})
		}?
		environment = Plugin.reference_config(context, "environment")?
		pkgs = Fields.get_strings(environment, "packages") ? |_|
			{
				byte_offset: None,
				message: "validated machine environment is missing 'packages'",
			}
		overlays = EnvironmentNix.extract_overlays(environment)?
		locked_overlays = EnvironmentNix.all_overlays(context)?
		system = Fields.get_string(context.config, "system") ? |_|
			{
				byte_offset: None,
				message: "validated machine configuration is missing 'system'",
			}
		users = MachineNix.optional_strings(context.config, "users")?
		services = MachineNix.optional_strings(context.config, "services")?
		failures = Plugin.validate_text(name, MachineConfig.name_rules)
			.concat(Plugin.validate_string_list(pkgs, NixBackend.package_rules))
			.concat(MachineConfig.user_failures(users))
			.concat(MachineConfig.service_failures(services))
		Plugin.renderer_validation(failures)?
		target = NixBackend.machine_target(
			system,
			context.host_os,
			context.host_arch,
		) ? |problem|
			match problem {
				UnsupportedMachineSystem => {
					byte_offset: None,
					message: Str.join_with(
						[
							"unsupported NixOS machine system '${system}'; ",
							"expected 'x86_64-linux' or 'aarch64-linux'",
						],
						"",
					),
				}
				UnsupportedMachineHost => {
					byte_offset: None,
					message: "NixOS machine builds are supported only on Linux hosts",
				}
				CrossArchitectureMachine => {
					byte_offset: None,
					message: Str.join_with(
						[
							"cross-architecture NixOS machine builds are not ",
							"supported; target '${system}' must match the host ",
							"architecture",
						],
						"",
					),
				}
			}
		generated_services = services.keep_if(
			|service| MachineNix.has_service_declaration(context, service),
		)
		Ok(
			MachineNix.Configuration.{
				generated_services,
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
		requests = MachineNix.service_requests(
			config.generated_services,
			"machine",
		)
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
		native_services = config.services.keep_if(
			|service| !config.generated_services.contains(service),
		)
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
		flake = MachineNix.render_flake(
			config.name,
			config.target_system,
			config.locked_overlays,
			config.overlays,
			services,
		)
		module_text = MachineNix.render_module(
			config.pkgs,
			config.users,
			native_services,
		)
		metadata = MachineNix.render_metadata(machine_metadata)
		Ok(
			Plugin.RenderResult.{
				actions: NixBackend.machine_actions(
					config.name,
					flake,
					module_text,
					metadata,
					services,
				),
				artifacts: [
					{
						attributes: [
							{ key: "backend", value: NixBackend.backend.name },
							{
								key: "target.architecture",
								value: config.target_architecture,
							},
							{ key: "target.system", value: config.target_system },
						],
						kind: "kai.machine.closure/v1",
						name: config.name,
						path: NixBackend.machine_closure_path(config.name),
					},
				],
				outputs: [],
				requests,
				requested_packages: config.pkgs,
			},
		)
	}

	has_service_declaration : Plugin.RenderContext, Str -> Bool
	has_service_declaration = |context, name|
		List.any(
			Plugin.project_configs(context, ["service"]),
			|entry|
				match entry.header {
					["service", declared] => declared == name
					["service", declared, _] => declared == name
					_ => Bool.False
				},
		)

	service_requests : List(Str), Str -> List(Plugin.PlanRequest)
	service_requests = |services, command|
		services.map(
			|service| {
				args: ["service", NixBackend.backend.name, service],
				status: "${command}: service ${service}",
			},
		)

	resolve_services :
		List(Plugin.Artifact),
		List(Str),
		Str ->
			Try(
				List(Plugin.Artifact),
				Plugin.RendererDiagnostic,
			)
	resolve_services = |artifacts, names, system|
		match names {
			[] => Ok([])
			[first, .. as rest] => {
				service = MachineNix.find_service(artifacts, first)?
				MachineNix.validate_service(service, system)?
				remaining = MachineNix.resolve_services(artifacts, rest, system)?
				Ok([service].concat(remaining))
			}
		}

	validate_service :
		Plugin.Artifact, Str -> Try({}, Plugin.RendererDiagnostic)
	validate_service = |service, system| {
		backend = MachineNix.attribute(service.attributes, "backend")?
		service_system = MachineNix.attribute(
			service.attributes,
			"target.system",
		)?
		path_failures = Plugin.validate_text(
			service.path,
			NixBackend.artifact_path_rules,
		)
		backend_failures = if backend == NixBackend.backend.name {
			[]
		} else {
			[
				Str.join_with(
					[
						"service artifact backend must be '",
						NixBackend.backend.name,
						"'",
					],
					"",
				),
			]
		}
		system_failures = if service_system == system {
			[]
		} else {
			[
				Str.join_with(
					[
						"service artifact targets '${service_system}', ",
						"expected '${system}'",
					],
					"",
				),
			]
		}
		Plugin.renderer_validation(
			backend_failures.concat(system_failures).concat(path_failures),
		)
	}

	attribute :
		List(Plugin.ArtifactAttribute), Str -> Try(Str, Plugin.RendererDiagnostic)
	attribute = |attributes, key|
		match attributes {
			[] => Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"service artifact is missing required '${key}' ",
						"attribute",
					],
					"",
				),
			})
			[first, .. as rest] => if first.key == key {
				Ok(first.value)
			} else {
				MachineNix.attribute(rest, key)
			}
		}

	find_service :
		List(Plugin.Artifact), Str -> Try(Plugin.Artifact, Plugin.RendererDiagnostic)
	find_service = |artifacts, name|
		match artifacts.keep_if(|artifact|
			artifact.kind == "kai.nixos.service/v1" and artifact.name == name) {
			[service] => Ok(service)
			[] => Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"service '${name}' did not produce a ",
						"kai.nixos.service/v1 artifact",
					],
					"",
				),
			})
			_ => Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"service '${name}' produced multiple ",
						"kai.nixos.service/v1 artifacts",
					],
					"",
				),
			})
		}

	service_module_lines : List(Plugin.Artifact) -> List(Str)
	service_module_lines = |services|
		services.map(|service| "          ./services/${service.name}")

	optional_strings :
		Fields.Configuration, Str -> Try(List(Str), Plugin.RendererDiagnostic)
	optional_strings = |config, field|
		match Fields.maybe_strings(config, field) {
			Ok(None) => Ok([])
			Ok(Some(values)) => Ok(values)
			Err(_) => Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"validated machine configuration has invalid ",
						"'${field}'",
					],
					"",
				),
			})
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

	render_flake : Str, Str, List(Str), List(Str), List(Plugin.Artifact) -> Str
	render_flake = |name, system, locked_overlays, overlays, services| {
		overlay_names = locked_overlays.map_with_index(
			|_, index| "overlay${U64.to_str(index)}",
		)
		overlay_lines = overlays.map(
			|overlay| {
				overlay_name = NixBackend.overlay_name(locked_overlays, overlay, 0)
				"          ${overlay_name}.overlays.default"
			},
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
			"          ./machine.nix",
		]).concat(MachineNix.service_module_lines(services)).concat([
			"        ];",
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
		package_lines = pkgs.map(
			|pkg| "    pkgs.${NixBackend.render_attributes(pkg)}",
		)
		user_lines = users.map(
			|user| "  users.users.\"${user}\".isNormalUser = true;",
		)
		service_lines = services.map(
			|service| {
				service_attr = NixBackend.render_attributes(service)
				"  services.${service_attr}.enable = true;"
			},
		)
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
