# An implementation for defining nix machine services.
import parser.Body
import kai.Plugin
import backends.Nix as NixBackend
import commands.Build as BuildCommand
import commands.Secret as SecretCommand
import commands.Service as ServiceCommand

ServiceNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [],
		backend: NixBackend.backend.name,
		command: ServiceCommand.command.call.name,
		renderer: ServiceNix.renderer,
		validator: NoValidation,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		name = match context.args {
			[selected_name] => Ok(selected_name)
			_ => Err({ byte_offset: None, message: "service requires exactly one name" })
		}?
		artifact_name = Body.get_string(context.config, "artifact") ? |_|
			{
				byte_offset: None,
				message: "validated service configuration is missing 'artifact'",
			}
		secrets = Body.get_strings(context.config, "secrets") ? |_|
			{
				byte_offset: None,
				message: "validated service configuration is missing 'secrets'",
			}
		restart = Body.get_string(context.config, "restart") ? |_|
			{
				byte_offset: None,
				message: "validated service configuration is missing 'restart'",
			}
		failures = ServiceCommand.name_failures(name)
			.concat(
				Plugin.validate_text(
					artifact_name,
					BuildCommand.artifact_name_rules,
				),
			)
			.concat(ServiceCommand.secret_failures(secrets))
			.concat(ServiceCommand.restart_failures(restart))
		Plugin.renderer_validation(failures)?
		if context.host_os != LINUX {
			Err({
				byte_offset: None,
				message: "NixOS service modules are supported only on Linux",
			})
		} else {
			ServiceNix.validate_secrets(context, secrets)?
			requests = ServiceNix.requests(artifact_name)
			if context.dependencies_resolved {
				build = ServiceNix.find_build(context.dependency_artifacts, artifact_name)?
				target = NixBackend.target(context.host_os, context.host_arch) ? |_|
					{ byte_offset: None, message: "unsupported service platform" }
				pkgs_flake = ServiceNix.validate_build(build, target.system)?
				module_text = ServiceNix.render_module(name, secrets, restart)
				expression = ServiceNix.render_expression(name, pkgs_flake, target.system)
				Ok(
					Plugin.RenderResult.{
						actions: NixBackend.service_actions(
							name,
							build.path,
							module_text,
							expression,
						),
						artifacts: [
							{
								attributes: [
									{ key: "backend", value: NixBackend.backend.name },
									{ key: "build", value: build.name },
									{ key: "target.system", value: target.system },
								],
								kind: "kai.nixos.service/v1",
								name,
								path: NixBackend.service_artifact_path(name),
							},
						],
						outputs: [],
						requests,
						requested_packages: [],
					},
				)
			} else {
				Ok(
					Plugin.RenderResult.{
						actions: [],
						artifacts: [],
						outputs: [],
						requests,
						requested_packages: [],
					},
				)
			}
		}
	}

	requests : Str -> List(Plugin.PlanRequest)
	requests = |artifact|
		[
			{
				args: ["build", NixBackend.backend.name, artifact],
				status: "service: build ${artifact}",
			},
		]

	find_build :
		List(Plugin.Artifact), Str -> Try(Plugin.Artifact, Plugin.RendererDiagnostic)
	find_build = |artifacts, name|
		match artifacts.keep_if(|artifact|
			artifact.kind == "kai.build/v1" and artifact.name == name) {
			[build] => Ok(build)
			[] => Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"build '${name}' did not produce a ",
						"kai.build/v1 artifact",
					],
					"",
				),
			})
			_ => Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"build '${name}' produced multiple ",
						"kai.build/v1 artifacts",
					],
					"",
				),
			})
		}

	validate_build : Plugin.Artifact, Str -> Try(Str, Plugin.RendererDiagnostic)
	validate_build = |build, system| {
		backend = ServiceNix.attribute(build.attributes, "backend")?
		build_system = ServiceNix.attribute(build.attributes, "target.system")?
		pkgs_flake = ServiceNix.attribute(build.attributes, "nix.pkgs-flake")?
		path_failures = Plugin.validate_text(
			build.path,
			NixBackend.artifact_path_rules,
		)
		flake_failures = Plugin.validate_text(
			pkgs_flake,
			NixBackend.artifact_path_rules,
		)
		failures = if backend == NixBackend.backend.name {
			path_failures
		} else {
			[
				Str.join_with(
					[
						"build artifact backend must be '",
						NixBackend.backend.name,
						"'",
					],
					"",
				),
			].concat(path_failures)
		}
		system_failures = if build_system == system {
			[]
		} else {
			["build artifact targets '${build_system}', expected '${system}'"]
		}
		Plugin.renderer_validation(
			system_failures.concat(failures).concat(flake_failures),
		)?
		Ok(pkgs_flake)
	}

	attribute :
		List(Plugin.ArtifactAttribute), Str -> Try(Str, Plugin.RendererDiagnostic)
	attribute = |attributes, key|
		match attributes {
			[] => Err({
				byte_offset: None,
				message: "artifact is missing required '${key}' attribute",
			})
			[first, .. as rest] => if first.key == key {
				Ok(first.value)
			} else {
				ServiceNix.attribute(rest, key)
			}
		}

	validate_secrets :
		Plugin.RenderContext, List(Str) -> Try({}, Plugin.RendererDiagnostic)
	validate_secrets = |context, names|
		match names {
			[] => Ok({})
			[first, .. as rest] => {
				entries = Plugin.project_configs(context, ["secret"])
				matches = entries.keep_if(
					|entry|
						match entry.header {
							["secret", name] | ["secret", name, _] => name == first
							_ => Bool.False
						},
				)
				qualified = matches.keep_if(|entry|
					entry.header == ["secret", first, NixBackend.backend.name])
				entry = match qualified {
					[selected] => Ok(selected)
					[] =>
						match matches.keep_if(|candidate| candidate.header == ["secret", first]) {
							[selected] => Ok(selected)
							_ => Err({
								byte_offset: None,
								message: "service references missing secret '${first}'",
							})
						}
					_ => Err({
						byte_offset: None,
						message: "service references ambiguous secret '${first}'",
					})
				}?
				provision = Body.get_string(entry.config, "provision") ? |_|
					{
						byte_offset: None,
						message: "validated secret '${first}' is missing 'provision'",
					}
				Plugin.renderer_validation(SecretCommand.provision_failures(provision))?
				ServiceNix.validate_secrets(context, rest)
			}
		}

	render_expression : Str, Str, Str -> Str
	render_expression = |name, pkgs_flake_path, system| {
		pkgs_flake = if pkgs_flake_path.starts_with("/") {
			pkgs_flake_path
		} else {
			"../../../${pkgs_flake_path}"
		}
		Str.join_with(
			[
				"let",
				"  flake = builtins.getFlake (toString ${pkgs_flake});",
				"  pkgs = builtins.getAttr \"${system}\" flake.legacyPackages;",
				"in",
				"pkgs.runCommand \"kai-service-${name}\" {} ''",
				"  mkdir -p \"$out\"",
				Str.join_with(
					[
						"  cp -- ",
						ServiceNix.nix_interpolation("./module.nix"),
						" \"$out/default.nix\"",
					],
					"",
				),
				Str.join_with(
					[
						"  cp --recursive --no-dereference --preserve=mode ",
						ServiceNix.nix_interpolation("./artifact"),
						" \"$out/artifact\"",
					],
					"",
				),
				"  if [ ! -f \"$out/artifact\" ] || [ ! -x \"$out/artifact\" ]; then",
				"    echo \"Kai service artifact must be an executable file\" >&2",
				"    exit 1",
				"  fi",
				"''",
			],
			"\n",
		)
	}

	render_module : Str, List(Str), Str -> Str
	render_module = |name, secrets, restart| {
		credential_lines = secrets.map(|secret|
			"        \"${secret}:/run/kai/secrets/${secret}\"")
		Str.join_with(
			[
				"{ ... }:",
				"{",
				"  systemd.tmpfiles.rules = [",
				"    \"d /run/kai/secrets 0700 root root -\"",
				"  ];",
				"  systemd.services.\"${name}\" = {",
				"    wantedBy = [ \"multi-user.target\" ];",
				"    serviceConfig = {",
				"      Type = \"exec\";",
				"      ExecStart = \"${ServiceNix.nix_interpolation("./artifact")}\";",
				"      Restart = \"${restart}\";",
				"      DynamicUser = true;",
				"      NoNewPrivileges = true;",
				"      PrivateDevices = true;",
				"      PrivateTmp = true;",
				"      ProtectControlGroups = true;",
				"      ProtectHome = true;",
				"      ProtectKernelModules = true;",
				"      ProtectKernelTunables = true;",
				"      ProtectSystem = \"strict\";",
				"      RestrictSUIDSGID = true;",
				"      UMask = \"0077\";",
				"      LoadCredential = [",
			]
				.concat(credential_lines)
				.concat([
					"      ];",
					"    };",
					"  };",
					"}",
				]),
			"\n",
		)
	}

	nix_interpolation : Str -> Str
	nix_interpolation = |expression| Str.join_with(["$", "{", expression, "}"], "")
}
