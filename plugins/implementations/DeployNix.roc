import parser.Body
import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Deploy as DeployCommand

DeployNix := [].{
	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: [],
		backend: NixBackend.backend.name,
		command: DeployCommand.command.name,
		renderer: DeployNix.renderer,
	}

	renderer : PluginApi.Renderer
	renderer = |context| {
		name = match context.args {
			[selected_name] => Ok(selected_name)
			# `kai deploy nix` selects the Nix backend before the standard selector
			# recognizes the colliding deployment name.
			[] => Ok(NixBackend.backend.name)
			_ => Err({ byte_offset: None, message: "deploy requires exactly one deployment name" })
		}?
		artifact = Body.get_string(context.config, "artifact") ? |_| {
			byte_offset: None,
			message: "validated deployment configuration is missing 'artifact'",
		}
		destination_text = Body.get_string(context.config, "to") ? |_| {
			byte_offset: None,
			message: "validated deployment configuration is missing 'to'",
		}
		failures = PluginApi.validate_text(name, DeployCommand.name_rules).concat(
			PluginApi.validate_text(artifact, DeployCommand.artifact_rules),
		)
		PluginApi.renderer_validation(failures)?
		destination = DeployCommand.parse_destination(destination_text) ? |_|
			{
				byte_offset: None,
				message: "deployment destination must be exactly ssh://user@host with a safe user and hostname",
			}
		target = match context.host_os {
			LINUX =>
				match NixBackend.target(context.host_os, context.host_arch) {
					Ok(supported) => Ok(supported)
					Err(_) => Err({ byte_offset: None, message: "unsupported deployment platform" })
				}
			_ => Err({ byte_offset: None, message: "unsupported deployment platform" })
		}?
		script = DeployNix.render_script(name, artifact, destination, target.system)
		Ok(
			PluginApi.RenderResult.{
				actions: NixBackend.deploy_actions(name, script),
				outputs: [],
				requests: [
					{
						args: ["build", artifact],
						requirement: PlanFrom({ backend: NixBackend.backend.name, plugin: "std" }),
						status: "deploy: build ${artifact}",
					},
				],
				requested_packages: [],
			},
		)
	}

	render_script : Str, Str, DeployCommand.Destination, Str -> Str
	render_script = |name, artifact, destination, system|
		Str.join_with(
			[
				"#!/bin/sh",
				"set -eu",
				"umask 077",
				"LC_ALL=C",
				"export LC_ALL",
				"",
				"deployment_name='${name}'",
				"artifact_path='.kai/artifacts/${artifact}'",
				"target='${destination.target}'",
				"store_url='${destination.store_url}'",
				"expected_system='${system}'",
				"",
				"store_path=$(nix path-info \"$artifact_path\")",
				"store_name=$(basename -- \"$store_path\")",
				"case \"$store_name\" in",
				"  ''|*[!A-Za-z0-9._-]*) echo \"Kai artifact did not resolve to a safe Nix store path\" >&2; exit 1 ;;",
				"esac",
				"if [ \"$store_path\" != \"/nix/store/$store_name\" ]; then",
				"  echo \"Kai artifact did not resolve to a Nix store path\" >&2",
				"  exit 1",
				"fi",
				"",
				"remote_system=$(ssh \"$target\" nix eval --raw --expr builtins.currentSystem)",
				"if [ \"$remote_system\" != \"$expected_system\" ]; then",
				"  echo \"Kai deployment system mismatch: expected $expected_system, got $remote_system\" >&2",
				"  exit 1",
				"fi",
				"",
				"nix copy --to \"$store_url\" \"$store_path\"",
				"ssh \"$target\" sh -s -- \"$deployment_name\" \"$store_path\" \"$expected_system\" <<'KAI_REMOTE'",
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
			"LC_ALL=C",
			"export LC_ALL",
			"",
			"if [ \"$#\" -ne 3 ]; then",
			"  echo \"Kai remote activation requires a deployment name, store path, and expected system\" >&2",
			"  exit 1",
			"fi",
			"name=$1",
			"store_path=$2",
			"expected_system=$3",
			"case \"$expected_system\" in",
			"  x86_64-linux|aarch64-linux) ;;",
			"  *) echo \"Kai received an invalid expected Nix system\" >&2; exit 1 ;;",
			"esac",
			"case \"$name\" in",
			"  ''|.*|*[!A-Za-z0-9._-]*) echo \"Kai received an invalid deployment name\" >&2; exit 1 ;;",
			"esac",
			"store_name=$(basename -- \"$store_path\")",
			"case \"$store_name\" in",
			"  ''|*[!A-Za-z0-9._-]*) echo \"Kai received an invalid store path\" >&2; exit 1 ;;",
			"esac",
			"if [ \"$store_path\" != \"/nix/store/$store_name\" ]; then",
			"  echo \"Kai received an invalid store path\" >&2",
			"  exit 1",
			"fi",
			"case \"$HOME\" in",
			"  /*) ;;",
			"  *) echo \"Kai requires an absolute remote HOME\" >&2; exit 1 ;;",
			"esac",
			"",
			"remote_system=$(nix eval --raw --expr builtins.currentSystem)",
			"if [ \"$remote_system\" != \"$expected_system\" ]; then",
			"  echo \"Kai deployment system mismatch during activation: expected $expected_system, got $remote_system\" >&2",
			"  exit 1",
			"fi",
			"if [ ! -e \"$store_path\" ] || ! nix path-info \"$store_path\" >/dev/null; then",
			"  echo \"Kai copied store path is not present on the remote host\" >&2",
			"  exit 1",
			"fi",
			"",
			"state_root=$HOME/.local/state/kai/deployments/$name",
			"generations=$state_root/generations",
			"current=$state_root/current",
			"lock=$state_root/lock",
			"mkdir -p \"$generations\"",
			"if ! mkdir \"$lock\"; then",
			"  if [ -d \"$lock\" ]; then",
			"    echo \"Kai deployment lock exists: $lock\" >&2",
			"    echo \"After confirming no deployment is running, remove it with: rmdir -- \\\"$lock\\\"\" >&2",
			"  else",
			"    echo \"Kai could not create the deployment lock: $lock\" >&2",
			"  fi",
			"  exit 1",
			"fi",
			"",
			"current_tmp=",
			"generation=",
			"generation_name=",
			"generation_created=0",
			"activation_completed=0",
			"cleanup() {",
			"  if [ \"$generation_created\" -eq 0 ] && [ -n \"$generation\" ] && [ -L \"$generation\" ]; then generation_created=1; fi",
			"  if [ \"$generation_created\" -eq 1 ] && [ \"$activation_completed\" -eq 0 ]; then",
			"    generation_is_active=0",
			"    if [ -L \"$current\" ]; then",
			"      if current_target=$(readlink \"$current\"); then",
			"        if [ \"$current_target\" = \"generations/$generation_name\" ]; then generation_is_active=1; fi",
			"      else",
			"        generation_is_active=1",
			"      fi",
			"    fi",
			"    if [ \"$generation_is_active\" -eq 0 ]; then rm -f -- \"$generation\"; fi",
			"  fi",
			"  if [ -n \"$current_tmp\" ]; then rm -f -- \"$current_tmp\"; fi",
			"  rmdir \"$lock\" 2>/dev/null || :",
			"}",
			"trap cleanup 0",
			"trap 'exit 1' 1 2 15",
			"",
			"generation_name=$(date -u +%Y%m%dT%H%M%SZ)-$$",
			"generation=$generations/$generation_name",
			"if [ -e \"$generation\" ] || [ -L \"$generation\" ]; then",
			"  echo \"Kai deployment generation already exists: $generation\" >&2",
			"  exit 1",
			"fi",
			"if ! nix-store --add-root \"$generation\" --indirect --realise \"$store_path\" >/dev/null; then",
			"  if [ -L \"$generation\" ]; then generation_created=1; fi",
			"  echo \"Kai deployment generation root could not be created\" >&2",
			"  exit 1",
			"fi",
			"if [ ! -L \"$generation\" ]; then",
			"  echo \"Kai deployment generation root was not created\" >&2",
			"  exit 1",
			"fi",
			"generation_created=1",
			"generation_path=$(nix path-info \"$generation\")",
			"if [ \"$generation_path\" != \"$store_path\" ]; then",
			"  echo \"Kai deployment generation points to the wrong store path\" >&2",
			"  exit 1",
			"fi",
			"",
			"current_tmp=$state_root/.current.$$",
			"ln -s \"generations/$generation_name\" \"$current_tmp\"",
			"if [ ! -L \"$current_tmp\" ]; then",
			"  echo \"Kai deployment current link was not created\" >&2",
			"  exit 1",
			"fi",
			"current_tmp_path=$(nix path-info \"$current_tmp\")",
			"if [ \"$current_tmp_path\" != \"$store_path\" ]; then",
			"  echo \"Kai deployment current link points to the wrong store path\" >&2",
			"  exit 1",
			"fi",
			"mv -Tf -- \"$current_tmp\" \"$current\"",
			"current_tmp=",
			"if [ ! -L \"$current\" ]; then",
			"  echo \"Kai deployment current link verification failed\" >&2",
			"  exit 1",
			"fi",
			"activated_target=$(readlink \"$current\")",
			"if [ \"$activated_target\" != \"generations/$generation_name\" ]; then",
			"  echo \"Kai deployment current link verification failed\" >&2",
			"  exit 1",
			"fi",
			"current_path=$(nix path-info \"$current\")",
			"if [ \"$current_path\" != \"$store_path\" ]; then",
			"  echo \"Kai deployment current path verification failed\" >&2",
			"  exit 1",
			"fi",
			"activation_completed=1",
		],
		"\n",
	)
}

# -- TESTS --

required_script_fragments = [
	"set -eu",
	"umask 077",
	"LC_ALL=C",
	"store_path=$(nix path-info \"$artifact_path\")",
	"''|*[!A-Za-z0-9._-]*)",
	"remote_system=$(ssh \"$target\" nix eval --raw --expr builtins.currentSystem)",
	"nix copy --to \"$store_url\" \"$store_path\"",
	"ssh \"$target\" sh -s -- \"$deployment_name\" \"$store_path\" \"$expected_system\" <<'KAI_REMOTE'",
	"if [ \"$#\" -ne 3 ]; then",
	"expected_system=$3",
	"if [ \"$remote_system\" != \"$expected_system\" ]; then",
	"state_root=$HOME/.local/state/kai/deployments/$name",
	"if ! mkdir \"$lock\"; then",
	"generation_created=0",
	"activation_completed=0",
	"if [ \"$generation_created\" -eq 0 ] && [ -n \"$generation\" ] && [ -L \"$generation\" ]; then generation_created=1; fi",
	"if [ \"$generation_created\" -eq 1 ] && [ \"$activation_completed\" -eq 0 ]; then",
	"if [ \"$generation_is_active\" -eq 0 ]; then rm -f -- \"$generation\"; fi",
	"nix-store --add-root \"$generation\" --indirect --realise \"$store_path\"",
	"generation_created=1",
	"ln -s \"generations/$generation_name\" \"$current_tmp\"",
	"mv -Tf -- \"$current_tmp\" \"$current\"",
	"activated_target=$(readlink \"$current\")",
	"current_path=$(nix path-info \"$current\")",
	"activation_completed=1",
]

fragment_before : Str, Str, Str -> Bool
fragment_before = |script, first, second|
	match script.split_on(first) {
		[_, after_first, ..] => after_first.contains(second)
		_ => Bool.False
	}

test_script = DeployNix.render_script(
	"production",
	"app",
	{ store_url: "ssh-ng://user@host", target: "user@host" },
	"x86_64-linux",
)

expect List.all(required_script_fragments, |fragment| test_script.contains(fragment))
expect test_script.contains("deployment_name='production'")
expect test_script.contains("artifact_path='.kai/artifacts/app'")
expect test_script.contains("target='user@host'")
expect test_script.contains("store_url='ssh-ng://user@host'")
expect fragment_before(DeployNix.remote_script, "name=$1", "store_path=$2")
expect fragment_before(DeployNix.remote_script, "store_path=$2", "expected_system=$3")
expect fragment_before(DeployNix.remote_script, "remote_system=$(nix eval --raw --expr builtins.currentSystem)", "state_root=$HOME")
expect fragment_before(DeployNix.remote_script, "rm -f -- \"$generation\"", "rm -f -- \"$current_tmp\"")
expect fragment_before(DeployNix.remote_script, "mv -Tf -- \"$current_tmp\" \"$current\"", "current_path=$(nix path-info \"$current\")")
expect fragment_before(DeployNix.remote_script, "current_path=$(nix path-info \"$current\")", "activation_completed=1")
expect !test_script.contains("StrictHostKeyChecking")
expect !test_script.contains("\neval ")
expect !DeployNix.remote_script.contains("rm -rf")

parsed_deploy = Body.parse(DeployCommand.body, "artifact: app\nto: \"ssh://user@host\"")

expect match parsed_deploy {
	Err(_) => Bool.False
	Ok(config) =>
		match DeployNix.renderer({
			args: ["production"],
			config,
			config_block: NoConfigBlock,
			host_arch: X64,
			host_os: LINUX,
			related_config: NoRelatedConfig,
		}) {
			Err(_) => Bool.False
			Ok(rendered) =>
				rendered.requests == [
					{
						args: ["build", "app"],
						requirement: PlanFrom({ backend: "nix", plugin: "std" }),
						status: "deploy: build app",
					},
				] and
					match rendered.actions {
						[WriteUtf8(write), Exec(exec)] =>
							write.path == ".kai/deployments/production.sh" and
								exec.command == "sh" and
									exec.args == [".kai/deployments/production.sh"]
						_ => Bool.False
					}
			}
	}

expect match parsed_deploy {
	Err(_) => Bool.False
	Ok(config) =>
		DeployNix.renderer({
			args: ["production"],
			config,
			config_block: NoConfigBlock,
			host_arch: AARCH64,
			host_os: MACOS,
			related_config: NoRelatedConfig,
		}) == Err({ byte_offset: None, message: "unsupported deployment platform" })
	}
