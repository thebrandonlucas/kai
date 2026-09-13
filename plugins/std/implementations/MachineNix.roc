# Implements NixOS machine builds and service module integration.
import parser.Fields
import kai.Plugin
import backends.Nix as NixBackend
import blocks.Machine as MachineBlock
import blocks.Secret as SecretBlock
import commands.Machine as MachineCommand
import EnvironmentNix

MachineNix := [].{
	SecretSpec := { file : Str, name : Str }

	MachineStepsInput := {
		flake : Str,
		metadata : Str,
		module_text : Str,
		secrets : List(SecretSpec),
		services : List(Plugin.Artifact),
	}

	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: MachineCommand.command_syntax.name,
		plan: MachineNix.plan,
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

	MachineSpec := {
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

	MachineTarget := { architecture : Str, system : Str }

	machine_target :
		Str,
		Plugin.HostOs,
		Plugin.HostArch ->
			Try(
				MachineTarget,
				[
					CrossArchitectureMachine,
					UnsupportedMachineHost,
					UnsupportedMachineSystem,
				],
			)
	machine_target = |system, os, arch|
		match (system, os, arch) {
			("x86_64-linux", LINUX, X64) => Ok({ architecture: "x86_64", system })
			("aarch64-linux", LINUX, AARCH64) => Ok({ architecture: "aarch64", system })
			("x86_64-linux", LINUX, _) => Err(CrossArchitectureMachine)
			("aarch64-linux", LINUX, _) => Err(CrossArchitectureMachine)
			("x86_64-linux", _, _) => Err(UnsupportedMachineHost)
			("aarch64-linux", _, _) => Err(UnsupportedMachineHost)
			_ => Err(UnsupportedMachineSystem)
		}

	machine_closure_path : Str, Str -> Str
	machine_closure_path = |workspace_root, name|
		Plugin.workspace_path(workspace_root, "artifacts/machines/${name}/closure")

	machine_flake_path : Str, Str -> Str
	machine_flake_path = |workspace_root, name|
		Plugin.workspace_path(workspace_root, "machines/${name}")

	machine_metadata_path : Str, Str -> Str
	machine_metadata_path = |workspace_root, name|
		Plugin.workspace_path(
			workspace_root,
			"artifacts/machines/${name}/metadata.json",
		)

	service_copy_steps : Str, List(Plugin.Artifact) -> List(Plugin.ExecutionStep)
	service_copy_steps = |flake_path, services| {
		service_path = "${flake_path}/services"
		[
			RunProgram({ arguments: ["-rf", service_path], program: "rm" }),
			RunProgram({ arguments: ["-p", service_path], program: "mkdir" }),
		].concat(
			services.map(
				|service|
					RunProgram({
						arguments: [
							"-RH",
							"--preserve=mode",
							"--",
							service.path,
							"${service_path}/${service.name}",
						],
						program: "cp",
					}),
			),
		).concat([
			RunProgram({
				arguments: ["-R", "u+w", "--", service_path],
				program: "chmod",
			}),
		])
	}

	stage_secret_script : Str
	stage_secret_script =
		\\workspace=$1
		\\source=$2
		\\directory=$3
		\\destination=$4
		\\if ! command -v sops >/dev/null 2>&1; then
		\\  echo "cannot stage secrets: 'sops' was not found" >&2
		\\  exit 1
		\\fi
		\\canonical_source=$(realpath -e -- "$source")
		\\literal_source=$(realpath -e -s -- "$source")
		\\canonical_workspace=$(realpath -e -- "$workspace")
		\\if [ ! -f "$source" ] || [ "$canonical_source" != "$literal_source" ]; then
		\\  echo "secret source must be a regular path without symlinks" >&2
		\\  exit 1
		\\fi
		\\case "$canonical_source" in
		\\  "$canonical_workspace"|"$canonical_workspace"/*)
		\\    echo "secret source must be outside the Kai workspace" >&2
		\\    exit 1
		\\    ;;
		\\esac
		\\encrypted_binary() {
		\\  file=$(realpath -e -- "$1") || return 1
		\\  status=$(sops filestatus --input-type json "$file") || return 1
		\\  test "$status" = '{"encrypted":true}' || return 1
		\\  envelope=$(
		\\    KAI_SECRET_FILE="$file" nix eval --impure --raw --expr '
		\\      let
		\\        value = builtins.fromJSON (
		\\          builtins.readFile (builtins.getEnv "KAI_SECRET_FILE")
		\\        );
		\\      in
		\\      if builtins.isAttrs value
		\\        && builtins.attrNames value == [ "data" "sops" ]
		\\        && builtins.isString value.data
		\\        && builtins.match
		\\          "ENC[[]AES256_GCM,data:[^,]+,iv:[^,]+,tag:[^,]+,type:str[]]"
		\\          value.data != null
		\\      then "true"
		\\      else "false"
		\\    '
		\\  ) || return 1
		\\  test "$envelope" = true
		\\}
		\\if ! encrypted_binary "$source"; then
		\\  echo "secret source must be SOPS binary JSON" >&2
		\\  exit 1
		\\fi
		\\if [ -L "$directory" ]; then
		\\  echo "temporary secrets path must not be a symlink" >&2
		\\  exit 1
		\\fi
		\\mkdir -p -- "$directory"
		\\cp --no-dereference --remove-destination -- "$source" "$destination"
		\\if [ -L "$destination" ] || [ ! -f "$destination" ] ||
		\\  ! encrypted_binary "$destination"
		\\then
		\\  rm -f -- "$destination"
		\\  echo "staged secret must be SOPS binary JSON" >&2
		\\  exit 1
		\\fi

	secret_stage_steps :
		Str, Str, List(SecretSpec) -> List(Plugin.ExecutionStep)
	secret_stage_steps = |workspace_root, flake_path, secrets| {
		secrets_path = "${flake_path}/secrets"
		temporary_path = "${flake_path}/secrets.tmp"
		clear_steps = [
			RunProgram({
				arguments: ["-rf", "--", secrets_path, temporary_path],
				program: "rm",
			}),
		]
		stage_steps = secrets.map(
			|secret|
				RunProgram({
					arguments: [
						"-ceu",
						MachineNix.stage_secret_script,
						"kai-stage-secret",
						workspace_root,
						secret.file,
						temporary_path,
						"${temporary_path}/${secret.name}.json",
					],
					program: "sh",
				}),
		)
		publish_steps = if secrets.is_empty() {
			[]
		} else {
			[
				RunProgram({
					arguments: ["-T", "--", temporary_path, secrets_path],
					program: "mv",
				}),
			]
		}
		clear_steps.concat(stage_steps).concat(publish_steps)
	}

	machine_steps :
		Str, Str, MachineStepsInput -> List(Plugin.ExecutionStep)
	machine_steps = |root, name, input| {
		flake_path = MachineNix.machine_flake_path(root, name)
		metadata_path = MachineNix.machine_metadata_path(root, name)
		[
			# Empty metadata invalidates an older artifact before any fallible step.
			WriteFile({ contents: "", path: metadata_path }),
			WriteFile({
				contents: input.flake,
				path: "${flake_path}/flake.nix",
			}),
			WriteFile({
				contents: input.module_text,
				path: "${flake_path}/machine.nix",
			}),
		]
			.concat(MachineNix.service_copy_steps(flake_path, input.services))
			.concat(MachineNix.secret_stage_steps(root, flake_path, input.secrets))
			.concat(NixBackend.lock_steps(flake_path))
			.concat([
				WriteFile({
					contents: "",
					path: Plugin.workspace_path(
						root,
						"artifacts/machines/${name}/.keep",
					),
				}),
				NixBackend.run([
					"build",
					"path:${flake_path}#kaiMachines.\"${name}\".closure",
					"--no-update-lock-file",
					"--out-link",
					MachineNix.machine_closure_path(root, name),
				]),
				WriteFile({ contents: input.metadata, path: metadata_path }),
			])
	}

	machine_spec :
		Plugin.CommandPlanningInput,
		Str ->
			Try(
				MachineSpec,
				Plugin.BackendPlanningDiagnostic,
			)
	machine_spec = |input, command_name| {
		name = match input.command_arguments {
			[selected_name] => Ok(selected_name)
			_ => Err({
				byte_offset: None,
				message: "${command_name} requires exactly one name",
			})
		}?
		environment = Plugin.referenced_fields(input, "environment")?
		pkgs = Fields.get_strings(environment, "packages") ? |_|
			{
				byte_offset: None,
				message: "validated machine environment is missing 'packages'",
			}
		overlays = EnvironmentNix.extract_overlays(environment)?
		locked_overlays = EnvironmentNix.all_overlays(input)?
		system = Fields.get_string(input.command_fields, "system") ? |_|
			{
				byte_offset: None,
				message: "validated machine block is missing 'system'",
			}
		users = MachineNix.optional_strings(input.command_fields, "users")?
		services = MachineNix.optional_strings(input.command_fields, "services")?
		failures = Plugin.validate_text(name, MachineBlock.name_rules)
			.concat(Plugin.validate_string_list(pkgs, NixBackend.package_rules))
			.concat(MachineBlock.user_failures(users))
			.concat(MachineBlock.service_failures(services))
		Plugin.implementation_validation(failures)?
		target = MachineNix.machine_target(
			system,
			input.host.os,
			input.host.arch,
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
			|service| MachineNix.has_service_declaration(input, service),
		)
		Ok(
			MachineNix.MachineSpec.{
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

	plan :
		Plugin.CommandPlanningInput ->
			Try(
				Plugin.BackendCommandPlan,
				Plugin.BackendPlanningDiagnostic,
			)
	plan = |input| {
		spec = MachineNix.machine_spec(input, "machine")?
		prerequisite_commands = MachineNix.service_prerequisite_commands(
			spec.generated_services,
			"machine",
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
		native_services = spec.services.keep_if(
			|service| !spec.generated_services.contains(service),
		)
		secrets = MachineNix.collect_secrets(
			services,
			input.workspace_root,
		)?
		if !secrets.is_empty() and !native_services.contains("openssh") {
			return Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"machines with secrets require the native NixOS service ",
						"'openssh' and an existing ",
						"/etc/ssh/ssh_host_ed25519_key whose recipient encrypted ",
						"the secret files",
					],
					"",
				),
			})
		}
		machine_metadata = MachineNix.MachineMetadata.{
			backend: NixBackend.backend.name,
			closure_path: MachineNix.machine_closure_path(
				input.workspace_root,
				spec.name,
			),
			flake_attribute: "kaiMachines.\"${spec.name}\".closure",
			flake_path: MachineNix.machine_flake_path(input.workspace_root, spec.name),
			metadata_path: MachineNix.machine_metadata_path(
				input.workspace_root,
				spec.name,
			),
			name: spec.name,
			target_architecture: spec.target_architecture,
			target_system: spec.target_system,
		}
		flake = MachineNix.render_flake(
			spec.name,
			spec.target_system,
			spec.locked_overlays,
			spec.overlays,
			services,
			secrets,
		)
		module_text = MachineNix.render_module(
			spec.pkgs,
			spec.users,
			native_services,
			secrets,
		)
		metadata = MachineNix.render_metadata(machine_metadata)
		Ok(
			Plugin.BackendCommandPlan.{
				artifacts: [
					{
						attributes: [
							{ key: "backend", value: NixBackend.backend.name },
							{
								key: "target.architecture",
								value: spec.target_architecture,
							},
							{ key: "target.system", value: spec.target_system },
						],
						kind: "kai.machine.closure/v1",
						name: spec.name,
						path: MachineNix.machine_closure_path(input.workspace_root, spec.name),
					},
				],
				prerequisite_commands,
				requested_packages: spec.pkgs,
				steps: MachineNix.machine_steps(
					input.workspace_root,
					spec.name,
					MachineNix.MachineStepsInput.{
						flake,
						metadata,
						module_text,
						secrets,
						services,
					},
				),
			},
		)
	}

	has_service_declaration : Plugin.CommandPlanningInput, Str -> Bool
	has_service_declaration = |input, name|
		List.any(
			Plugin.blocks_of_kind(input, ["service"]),
			|entry|
				match entry.header {
					["service", declared] => declared == name
					["service", declared, _] => declared == name
					_ => Bool.False
				},
		)

	service_prerequisite_commands :
		List(Str), Str -> List(Plugin.PrerequisiteCommand)
	service_prerequisite_commands = |services, command|
		services.map(
			|service| {
				arguments: ["service", NixBackend.backend.name, service],
				description: "${command}: service ${service}",
			},
		)

	resolve_services :
		List(Plugin.Artifact),
		List(Str),
		Str ->
			Try(
				List(Plugin.Artifact),
				Plugin.BackendPlanningDiagnostic,
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
		Plugin.Artifact, Str -> Try({}, Plugin.BackendPlanningDiagnostic)
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
		Plugin.implementation_validation(
			backend_failures.concat(system_failures).concat(path_failures),
		)
	}

	attribute :
		List(Plugin.ArtifactAttribute),
		Str ->
			Try(
				Str,
				Plugin.BackendPlanningDiagnostic,
			)
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
		List(Plugin.Artifact),
		Str ->
			Try(
				Plugin.Artifact,
				Plugin.BackendPlanningDiagnostic,
			)
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

	collect_secrets :
		List(Plugin.Artifact),
		Str ->
			Try(
				List(SecretSpec),
				Plugin.BackendPlanningDiagnostic,
			)
	collect_secrets = |services, workspace_root|
		MachineNix.collect_service_secrets(services, workspace_root, [])

	collect_service_secrets :
		List(Plugin.Artifact),
		Str,
		List(SecretSpec) ->
			Try(
				List(SecretSpec),
				Plugin.BackendPlanningDiagnostic,
			)
	collect_service_secrets = |services, workspace_root, collected|
		match services {
			[] => Ok(collected)
			[first, .. as rest] => {
				next = MachineNix.collect_secret_attributes(
					first.attributes,
					workspace_root,
					collected,
				)?
				MachineNix.collect_service_secrets(rest, workspace_root, next)
			}
		}

	collect_secret_attributes :
		List(Plugin.ArtifactAttribute),
		Str,
		List(SecretSpec) ->
			Try(
				List(SecretSpec),
				Plugin.BackendPlanningDiagnostic,
			)
	collect_secret_attributes = |attributes, workspace_root, collected|
		match attributes {
			[] => Ok(collected)
			[first, .. as rest] => {
				is_secret = first.key == "secret" or
					first.key.starts_with("secret.")
				if !is_secret {
					MachineNix.collect_secret_attributes(
						rest,
						workspace_root,
						collected,
					)
				} else {
					name = match first.key.split_on(".") {
						["secret", parsed_name, "file"] => Ok(parsed_name)
						_ => Err({
							byte_offset: None,
							message: Str.join_with(
								[
									"malformed service secret metadata '",
									first.key,
									"'; expected 'secret.<NAME>.file'",
								],
								"",
							),
						})
					}?
					failures = SecretBlock.name_failures(name)
						.concat(SecretBlock.file_failures(first.value))
						.concat(
							SecretBlock.workspace_file_failures(
								first.value,
								workspace_root,
							),
						)
					Plugin.implementation_validation(failures)?
					next = MachineNix.insert_secret(
						collected,
						{ file: first.value, name },
					)?
					MachineNix.collect_secret_attributes(
						rest,
						workspace_root,
						next,
					)
				}
			}
		}

	insert_secret :
		List(SecretSpec),
		SecretSpec ->
			Try(
				List(SecretSpec),
				Plugin.BackendPlanningDiagnostic,
			)
	insert_secret = |secrets, candidate|
		match secrets.keep_if(|secret| secret.name == candidate.name) {
			[] => Ok(secrets.concat([candidate]))
			[first, ..] => if first.file == candidate.file {
				Ok(secrets)
			} else {
				Err({
					byte_offset: None,
					message: Str.join_with(
						[
							"secret '",
							candidate.name,
							"' maps to different files in service artifacts",
						],
						"",
					),
				})
			}
		}

	service_module_lines : List(Plugin.Artifact) -> List(Str)
	service_module_lines = |services|
		services.map(|service| "          ./services/${service.name}")

	optional_strings :
		Fields.ParsedFields, Str -> Try(List(Str), Plugin.BackendPlanningDiagnostic)
	optional_strings = |fields, field|
		match Fields.maybe_strings(fields, field) {
			Ok(None) => Ok([])
			Ok(Some(values)) => Ok(values)
			Err(_) => Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"validated machine block has invalid ",
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

	render_flake :
		Str, Str, List(Str), List(Str), List(Plugin.Artifact), List(SecretSpec) -> Str
	render_flake =
		|name, system, locked_overlays, overlays, services, secrets| {
			overlay_lines = overlays.map(
				|overlay|
					"          ${NixBackend.overlay_expression(locked_overlays, overlay, 0)}",
			)
			outputs_args = NixBackend.overlay_outputs_args(locked_overlays)
			sops_input_lines = if secrets.is_empty() {
				[]
			} else {
				[
					"  inputs.sops-nix = {",
					"    url = \"github:Mic92/sops-nix\";",
					"    inputs.nixpkgs.follows = \"nixpkgs\";",
					"  };",
				]
			}
			sops_outputs_arg = if secrets.is_empty() "" else ", sops-nix"
			sops_module_lines = if secrets.is_empty() {
				[]
			} else {
				["          sops-nix.nixosModules.sops"]
			}
			lines = [
				"{",
				"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
			].concat(sops_input_lines)
				.concat(NixBackend.input_lines(locked_overlays))
				.concat([
					"  outputs = { ${outputs_args}${sops_outputs_arg}, ... }:",
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
			]).concat(sops_module_lines)
				.concat(MachineNix.service_module_lines(services))
				.concat([
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

	render_module : List(Str), List(Str), List(Str), List(SecretSpec) -> Str
	render_module = |pkgs, users, services, secrets| {
		package_lines = pkgs.map(
			|pkg| "    pkgs.${NixBackend.render_attribute_path(pkg)}",
		)
		user_lines = users.map(
			|user| "  users.users.\"${user}\".isNormalUser = true;",
		)
		service_lines = services.map(
			|service| {
				service_attr = NixBackend.render_attribute_path(service)
				"  services.${service_attr}.enable = true;"
			},
		)
		secret_lines = secrets.map(
			|secret|
				Str.join_with(
					[
						"  sops.secrets.\"${secret.name}\" = {\n",
						"    format = \"binary\";\n",
						"    sopsFile = ./secrets/${secret.name}.json;\n",
						"  };",
					],
					"",
				),
		)
		secret_config_lines = if secrets.is_empty() {
			[]
		} else {
			[
				"  # Native OpenSSH is required, and this key must already exist.",
				"  # Its recipient must have encrypted every SOPS file.",
				Str.join_with(
					[
						"  sops.age.sshKeyPaths = [ ",
						"\"/etc/ssh/ssh_host_ed25519_key\" ];",
					],
					"",
				),
			].concat(secret_lines)
		}
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
		]).concat(user_lines)
			.concat(service_lines)
			.concat(secret_config_lines)
			.concat([
				"}",
			])
		Str.join_with(lines, "\n")
	}
}
