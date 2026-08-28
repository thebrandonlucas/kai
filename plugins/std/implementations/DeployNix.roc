# Implements remote deployment of Nix build artifacts.
import parser.Fields
import kai.Plugin
import backends.Nix as NixBackend
import commands.Build as BuildCommand
import commands.Deploy as DeployCommand

DeployNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [],
		backend: NixBackend.backend.name,
		command: DeployCommand.command.call.name,
		renderer: DeployNix.renderer,
		validator: NoValidation,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		name = match context.args {
			[selected] => Ok(selected)
			_ => Err({
				byte_offset: None,
				message: "deploy requires exactly one deployment name",
			})
		}?
		artifact_name = Fields.get_string(context.config, "artifact") ? |_|
			{
				byte_offset: None,
				message: Str.join_with(
					["validated deployment configuration ", "is missing 'artifact'"],
					"",
				),
			}
		destination_text = Fields.get_string(context.config, "to") ? |_|
			{
				byte_offset: None,
				message: Str.join_with(
					["validated deployment configuration ", "is missing 'to'"],
					"",
				),
			}
		failures = Plugin.validate_text(name, DeployCommand.name_rules).concat(
			Plugin.validate_text(
				artifact_name,
				BuildCommand.artifact_name_rules,
			),
		)
		Plugin.renderer_validation(failures)?
		destination = DeployCommand.parse_destination(destination_text) ? |_|
			{
				byte_offset: None,
				message: Str.join_with(
					[
						"deployment destination must be exactly ",
						"ssh://user@host with a safe user and hostname",
					],
					"",
				),
			}
		target = match context.host_os {
			LINUX => NixBackend.target(
				context.host_os,
				context.host_arch,
			) ? |_| {
				byte_offset: None,
				message: "unsupported deployment platform",
			}
			_ => return Err({
				byte_offset: None,
				message: "unsupported deployment platform",
			})
		}
		requests = [
			{
				args: ["build", NixBackend.backend.name, artifact_name],
				status: "deploy: build ${artifact_name}",
			},
		]
		if !context.dependencies_resolved {
			return Ok({
				actions: [],
				artifacts: [],
				outputs: [],
				requests,
				requested_packages: [],
			})
		}
		artifact = DeployNix.find_build(
			context.dependency_artifacts,
			artifact_name,
		)?
		DeployNix.validate_build(artifact, target.system)?
		script = DeployNix.render_script(
			name,
			artifact.path,
			destination,
			target.system,
		)
		Ok(
			Plugin.RenderResult.{
				actions: [
					WriteUtf8({
						content: script,
						path: ".kai/deployments/${name}.sh",
					}),
					Exec({
						args: [".kai/deployments/${name}.sh"],
						command: "sh",
					}),
				],
				artifacts: [],
				outputs: [],
				requests,
				requested_packages: [],
			},
		)
	}

	find_build : List(Plugin.Artifact),
	Str -> Try(
		Plugin.Artifact,
		Plugin.RendererDiagnostic,
	)
	find_build = |artifacts, name|
		match artifacts.keep_if(
			|artifact|
				artifact.kind == "kai.build/v1" and artifact.name == name,
		) {
			[build] => Ok(build)
			[] => Err({
				byte_offset: None,
				message: Str.join_with(
					["build '${name}' did not produce ", "a kai.build/v1 artifact"],
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

	validate_build : Plugin.Artifact, Str -> Try({}, Plugin.RendererDiagnostic)
	validate_build = |artifact, system| {
		backend = DeployNix.attribute(artifact.attributes, "backend")?
		artifact_system = DeployNix.attribute(
			artifact.attributes,
			"target.system",
		)?
		path_failures = Plugin.validate_text(
			artifact.path,
			NixBackend.artifact_path_rules,
		)
		backend_failures = if backend == NixBackend.backend.name {
			[]
		} else {
			["build artifact backend must be '${NixBackend.backend.name}'"]
		}
		system_failures = if artifact_system == system {
			[]
		} else {
			[
				Str.join_with(
					[
						"build artifact targets '${artifact_system}', ",
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

	attribute : List(Plugin.ArtifactAttribute),
	Str -> Try(
		Str,
		Plugin.RendererDiagnostic,
	)
	attribute = |attributes, key|
		match attributes {
			[] => Err({
				byte_offset: None,
				message: Str.join_with(
					["build artifact is missing required ", "'${key}' attribute"],
					"",
				),
			})
			[first, .. as rest] =>
				if first.key == key {
					Ok(first.value)
				} else {
					DeployNix.attribute(rest, key)
				}
			}

	join : List(Str) -> Str
	join = |parts| Str.join_with(parts, "")

	render_script : Str, Str, DeployCommand.Destination, Str -> Str
	render_script = |name, artifact_path, destination, system|
		Str.join_with(
			[
				"#!/bin/sh",
				"set -eu",
				"umask 077",
				"export LC_ALL=C",
				"deployment_name='${name}'",
				"artifact_path='${artifact_path}'",
				"target='${destination.target}'",
				"store_url='${destination.store_url}'",
				"expected_system='${system}'",
				"store_path=$(nix path-info \"$artifact_path\")",
				"store_name=$(basename -- \"$store_path\")",
				DeployNix.join([
					"case \"$store_name\" in ''|*[!A-Za-z0-9._-]*) ",
					"echo \"Kai artifact did not resolve to a safe Nix store path\" ",
					">&2; exit 1 ;; esac",
				]),
				DeployNix.join([
					"if [ \"$store_path\" != \"/nix/store/$store_name\" ]; then ",
					"echo \"Kai artifact did not resolve to a Nix store path\" ",
					">&2; exit 1; fi",
				]),
				DeployNix.join([
					"remote_system=$(ssh \"$target\" nix eval --raw ",
					"--expr builtins.currentSystem)",
				]),
				DeployNix.join([
					"if [ \"$remote_system\" != \"$expected_system\" ]; then ",
					"echo \"Kai deployment system mismatch: expected ",
					"$expected_system, got $remote_system\" >&2; exit 1; fi",
				]),
				"nix copy --to \"$store_url\" \"$store_path\"",
				DeployNix.join([
					"ssh \"$target\" sh -s -- \"$deployment_name\" ",
					"\"$store_path\" \"$expected_system\" <<'KAI_REMOTE'",
				]),
				DeployNix.remote_script,
				"KAI_REMOTE",
			],
			"\n",
		)

	remote_script : Str
	remote_script = Str.join_with(
		[
			"set -eu",
			"umask 077",
			"export LC_ALL=C",
			DeployNix.join([
				"if [ \"$#\" -ne 3 ]; then echo \"Kai remote activation ",
				"requires a deployment name, store path, and expected system\" ",
				">&2; exit 1; fi",
			]),
			"name=$1",
			"store_path=$2",
			"expected_system=$3",
			DeployNix.join([
				"case \"$name\" in ''|.*|*[!A-Za-z0-9._-]*) ",
				"echo \"Kai received an invalid deployment name\" ",
				">&2; exit 1 ;; esac",
			]),
			"store_name=$(basename -- \"$store_path\")",
			DeployNix.join([
				"case \"$store_name\" in ''|*[!A-Za-z0-9._-]*) ",
				"echo \"Kai received an invalid store path\" ",
				">&2; exit 1 ;; esac",
			]),
			DeployNix.join([
				"if [ \"$store_path\" != \"/nix/store/$store_name\" ]; then ",
				"echo \"Kai received an invalid store path\" >&2; exit 1; fi",
			]),
			"remote_system=$(nix eval --raw --expr builtins.currentSystem)",
			DeployNix.join([
				"if [ \"$remote_system\" != \"$expected_system\" ]; then ",
				"echo \"Kai deployment system mismatch during activation\" ",
				">&2; exit 1; fi",
			]),
			DeployNix.join([
				"if [ ! -e \"$store_path\" ] || ",
				"! nix path-info \"$store_path\" >/dev/null; then ",
				"echo \"Kai copied store path is not present on the remote host\" ",
				">&2; exit 1; fi",
			]),
			"state_root=$HOME/.local/state/kai/deployments/$name",
			"generations=$state_root/generations",
			"current=$state_root/current",
			"lock=$state_root/lock",
			"mkdir -p \"$generations\"",
			DeployNix.join([
				"if ! mkdir \"$lock\"; then echo ",
				"\"Kai deployment lock exists: $lock\" >&2; exit 1; fi",
			]),
			"current_tmp=",
			"generation=",
			"generation_name=",
			"generation_created=0",
			"activation_completed=0",
			"cleanup() {",
			DeployNix.join([
				"  if [ \"$generation_created\" -eq 0 ] && ",
				"[ -n \"$generation\" ] && [ -L \"$generation\" ]; then ",
				"generation_created=1; fi",
			]),
			"  generation_active=0",
			DeployNix.join([
				"  if [ -L \"$current\" ] && [ \"$(readlink \"$current\")\" = ",
				"\"generations/$generation_name\" ]; then ",
				"generation_active=1; fi",
			]),
			DeployNix.join([
				"  if [ \"$generation_created\" -eq 1 ] && ",
				"[ \"$activation_completed\" -eq 0 ] && ",
				"[ \"$generation_active\" -eq 0 ]; then ",
				"rm -f -- \"$generation\"; fi",
			]),
			DeployNix.join([
				"  if [ -n \"$current_tmp\" ]; then ",
				"rm -f -- \"$current_tmp\"; fi",
			]),
			"  rmdir \"$lock\" 2>/dev/null || :",
			"}",
			"trap cleanup 0",
			"trap 'exit 1' 1 2 15",
			"generation_name=$(date -u +%Y%m%dT%H%M%SZ)-$$",
			"generation=$generations/$generation_name",
			DeployNix.join([
				"if [ -e \"$generation\" ] || [ -L \"$generation\" ]; then ",
				"echo \"Kai deployment generation already exists\" ",
				">&2; exit 1; fi",
			]),
			DeployNix.join([
				"nix-store --add-root \"$generation\" --indirect ",
				"--realise \"$store_path\" >/dev/null",
			]),
			"generation_created=1",
			DeployNix.join([
				"if [ ! -L \"$generation\" ] || ",
				"[ \"$(nix path-info \"$generation\")\" != ",
				"\"$store_path\" ]; then echo ",
				"\"Kai deployment generation is invalid\" >&2; exit 1; fi",
			]),
			"current_tmp=$state_root/.current.$$",
			"ln -s \"generations/$generation_name\" \"$current_tmp\"",
			"mv -Tf -- \"$current_tmp\" \"$current\"",
			"current_tmp=",
			DeployNix.join([
				"if [ ! -L \"$current\" ] || ",
				"[ \"$(nix path-info \"$current\")\" != \"$store_path\" ]; then ",
				"echo \"Kai deployment current path verification failed\" ",
				">&2; exit 1; fi",
			]),
			"activation_completed=1",
			"retained=0",
			"for candidate in $(ls -1dt \"$generations\"/*); do",
			"  retained=$((retained + 1))",
			DeployNix.join([
				"  if [ \"$retained\" -gt 5 ] && ",
				"[ \"$candidate\" != \"$generation\" ]; then ",
				"rm -f -- \"$candidate\"; fi",
			]),
			"done",
		],
		"\n",
	)
}
