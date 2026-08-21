import kai.Plugin
import parser.Bytes

Nix := [].{
	backend : Plugin.Backend
	backend = Plugin.Backend.{
		determinate_system: Plugin.DeterminateSystem.{
			default_package_source: "nixpkgs",
			driver: Program("nix"),
			kind: Nix,
		},
		fallback: NoFallback,
		name: "nix",
		required_packages: [],
	}

	Target : { system : Str }

	target : Plugin.HostOs, Plugin.HostArch -> Try(Target, [UnsupportedPlatform])
	target = |os, arch|
		match (os, arch) {
			(LINUX, X64) => Ok({ system: "x86_64-linux" })
			(LINUX, AARCH64) => Ok({ system: "aarch64-linux" })
			(MACOS, X64) => Ok({ system: "x86_64-darwin" })
			(MACOS, AARCH64) => Ok({ system: "aarch64-darwin" })
			_ => Err(UnsupportedPlatform)
		}

	# Nix double-quoted strings accept printable ASCII except the characters
	# that begin escaping or interpolation.
	safe_string_rule : Str -> Plugin.TextRule
	safe_string_rule = |message|
		BytesInRanges({
			excluded: [Bytes.double_quote, Bytes.dollar_sign, Bytes.backslash],
			message,
			ranges: [{ max: Bytes.tilde, min: Bytes.exclamation_mark }],
		})

	package_rules : List(Plugin.StringListRule)
	package_rules = [
		AllStrings(NonemptyText("shell package names must not be empty")),
		AllStrings(DotSeparatedNonemptySegments("shell package attribute paths must not contain empty segments")),
		AllStrings(safe_string_rule("shell package attribute paths contain characters unsafe for Nix output")),
	]

	overlay_rules : List(Plugin.StringListRule)
	overlay_rules = [
		AllStrings(NonemptyText("shell overlay references must not be empty")),
		AllStrings(safe_string_rule("shell overlay references contain characters unsafe for Nix output")),
	]

	locked_flake_templates : List(Plugin.ActionTemplate)
	locked_flake_templates = [
		WriteConfigUtf8({ output: "flake", path: ".kai/flake.nix" }),
		Exec({
			args: [
				"flake",
				"lock",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				"kai.lock",
			],
			command: backend.name,
		}),
		Exec({
			args: [
				"flake",
				"lock",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				".kai/flake.lock",
			],
			command: backend.name,
		}),
	]

	shell_templates : List(Plugin.ActionTemplate)
	shell_templates = locked_flake_templates.concat([
		Exec({
			args: [
				"develop",
				"path:.kai#default",
				"--no-update-lock-file",
			],
			command: backend.name,
		}),
	])

	build_templates : List(Plugin.ActionTemplate)
	build_templates = locked_flake_templates.concat([
		WriteConfigUtf8({ output: "build_nix", path: ".kai/build.nix" }),
		WriteConfigUtf8({ output: "build_json", path: ".kai/build.json" }),
	])

	update_recipe : List(Plugin.ActionTemplate)
	update_recipe = [
		WriteConfigUtf8({ output: "flake", path: ".kai/flake.nix" }),
		Exec({
			args: [
				"flake",
				"update",
				"--flake",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				"kai.lock",
			],
			command: backend.name,
		}),
		Exec({
			args: [
				"flake",
				"lock",
				"path:.kai",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				".kai/flake.lock",
			],
			command: backend.name,
		}),
	]

	named_artifact_actions : Str -> List(Plugin.Action)
	named_artifact_actions = |name|
		[
			WriteUtf8({ content: "", path: ".kai/artifacts/.keep" }),
			Exec({
				args: [
					"build",
					"--file",
					".kai/build.nix",
					"--out-link",
					".kai/artifacts/${name}",
				],
				command: backend.name,
			}),
		]

	task_actions : List(Str) -> List(Plugin.Action)
	task_actions = |run|
		[
			Exec({
				args: [
					"develop",
					"path:.kai#default",
					"--no-update-lock-file",
					"--command",
				].concat(run),
				command: backend.name,
			}),
		]
}
