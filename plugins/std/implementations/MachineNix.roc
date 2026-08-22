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

	renderer : Plugin.Renderer
	renderer = |context| {
		name = match context.args {
			[selected_name] => Ok(selected_name)
			[] => Ok(NixBackend.backend.name)
			_ => Err({ byte_offset: None, message: "machine requires exactly one name" })
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
		machine_metadata = MachineNix.MachineMetadata.{
			backend: NixBackend.backend.name,
			closure_path: NixBackend.machine_closure_path(name),
			flake_attribute: "kaiMachines.\"${name}\".closure",
			flake_path: NixBackend.machine_flake_path(name),
			metadata_path: NixBackend.machine_metadata_path(name),
			name,
			target_architecture: target.architecture,
			target_system: target.system,
		}
		flake = MachineNix.render_flake(name, target.system, locked_overlays, overlays)
		module_text = MachineNix.render_module(pkgs, users, services)
		metadata = MachineNix.render_metadata(machine_metadata)
		Ok(
			Plugin.RenderResult.{
				actions: NixBackend.machine_actions(name, flake, module_text, metadata),
				outputs: [],
				requests: [],
				requested_packages: pkgs,
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

# -- TESTS --

machine_body = Str.join_with(
	[
		"environment: server",
		"system: \"x86_64-linux\"",
		"users: [\"agent\"]",
		"services: [\"openssh\"]",
	],
	"\n",
)

environment_body = "packages: [\"rocpkgs.nightly\"] overlays: [\"github:example/overlay\"]"

parsed_machine = Body.parse(MachineCommand.body, machine_body)

parsed_environment = Body.parse(Body.object([Body.required("packages", StringList), Body.optional("overlays", StringList)]), environment_body)

expect match (parsed_machine, parsed_environment) {
	(Ok(config), Ok(environment)) =>
		match MachineNix.renderer({
			args: ["agent"],
			config,
			config_block: NoConfigBlock,
			host_arch: X64,
			host_os: LINUX,
			project_config: [
				{
					block: "environment",
					config: environment,
					header: ["environment", "server"],
					location: { byte_offset: 0, column: 1, line: 1 },
				},
			],
			related_config: SelectedRelatedConfig({
				block: {
					body: environment_body,
					location: { byte_offset: 0, column: 1, line: 1 },
				},
				config: environment,
			}),
			target: NoTarget,
		}) {
			Err(_) => Bool.False
			Ok(rendered) => {
				expected_metadata = MachineNix.render_metadata(
					MachineNix.MachineMetadata.{
						backend: "nix",
						closure_path: ".kai/artifacts/machines/agent/closure",
						flake_attribute: "kaiMachines.\"agent\".closure",
						flake_path: ".kai/machines/agent",
						metadata_path: ".kai/artifacts/machines/agent/metadata.json",
						name: "agent",
						target_architecture: "x86_64",
						target_system: "x86_64-linux",
					},
				)
				match rendered.actions {
					[
						WriteUtf8(invalidate),
						WriteUtf8(flake),
						WriteUtf8(module_text),
						Exec(update_lock),
						Exec(copy_lock),
						WriteUtf8(marker),
						Exec(build),
						WriteUtf8(metadata),
					] =>
						invalidate.path == ".kai/artifacts/machines/agent/metadata.json" and
							invalidate.content == "" and
								flake.path == ".kai/machines/agent/flake.nix" and
									flake.content.contains("inputs.overlay0.url = \"github:example/overlay\";") and
										module_text.path == ".kai/machines/agent/machine.nix" and
											module_text.content.contains("services.\"openssh\".enable = true;") and
												update_lock.args == ["flake", "lock", "path:.kai/machines/agent", "--reference-lock-file", "kai.lock", "--output-lock-file", "kai.lock"] and
													copy_lock.args == ["flake", "lock", "path:.kai/machines/agent", "--reference-lock-file", "kai.lock", "--output-lock-file", ".kai/machines/agent/flake.lock"] and
														marker.path == ".kai/artifacts/machines/agent/.keep" and
															build.args == ["build", "path:.kai/machines/agent#kaiMachines.\"agent\".closure", "--no-update-lock-file", "--out-link", ".kai/artifacts/machines/agent/closure"] and
																metadata.path == ".kai/artifacts/machines/agent/metadata.json" and
																	metadata.content == expected_metadata
					_ => Bool.False
				}
			}
		}
	_ => Bool.False
}

machine_target_cases = [
	{ arch: X64, expected: Ok({ architecture: "x86_64", system: "x86_64-linux" }), os: LINUX, system: "x86_64-linux" },
	{ arch: X64, expected: Err(UnsupportedMachineHost), os: MACOS, system: "x86_64-linux" },
	{ arch: X64, expected: Err(CrossArchitectureMachine), os: LINUX, system: "aarch64-linux" },
	{ arch: X64, expected: Err(UnsupportedMachineSystem), os: LINUX, system: "x86_64-darwin" },
]

expect List.all(
	machine_target_cases,
	|case|
		match (NixBackend.machine_target(case.system, case.os, case.arch), case.expected) {
			(Ok(actual), Ok(expected)) => actual.architecture == expected.architecture and actual.system == expected.system
			(Err(actual), Err(expected)) => actual == expected
			_ => Bool.False
		},
)
