import kai.Plugin as PluginApi

Nix := [].{
	backend : PluginApi.Backend
	backend = PluginApi.Backend.{
		determinate_system: PluginApi.DeterminateSystem.{
			default_package_source: "nixpkgs",
			driver: Program("nix"),
			kind: Nix,
		},
		fallback: NoFallback,
		name: "nix",
		required_packages: [],
	}

	Target : { system : Str }

	target : PluginApi.HostOs, PluginApi.HostArch -> Try(Target, [UnsupportedPlatform])
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
	safe_string_rule : Str -> PluginApi.TextRule
	safe_string_rule = |message|
		BytesInRanges({
			excluded: [34, 36, 92],
			message,
			ranges: [{ max: 126, min: 33 }],
		})

	package_rules : List(PluginApi.StringListRule)
	package_rules = [
		AllStrings(NonemptyText("shell package names must not be empty")),
		AllStrings(DotSeparatedNonemptySegments("shell package attribute paths must not contain empty segments")),
		AllStrings(safe_string_rule("shell package attribute paths contain characters unsafe for Nix output")),
	]

	overlay_rules : List(PluginApi.StringListRule)
	overlay_rules = [
		AllStrings(NonemptyText("shell overlay references must not be empty")),
		AllStrings(safe_string_rule("shell overlay references contain characters unsafe for Nix output")),
	]

	locked_flake_templates : List(PluginApi.ActionTemplate)
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

	shell_templates : List(PluginApi.ActionTemplate)
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

	build_templates : List(PluginApi.ActionTemplate)
	build_templates = locked_flake_templates.concat([
		WriteConfigUtf8({ output: "build_nix", path: ".kai/build.nix" }),
		WriteConfigUtf8({ output: "build_json", path: ".kai/build.json" }),
	])

	update_recipe : List(PluginApi.ActionTemplate)
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

	named_artifact_actions : Str -> List(PluginApi.Action)
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

	task_actions : List(Str) -> List(PluginApi.Action)
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

	deploy_actions : Str, Str -> List(PluginApi.Action)
	deploy_actions = |name, script| {
		path = ".kai/deployments/${name}.sh"
		[
			WriteUtf8({ content: script, path }),
			Exec({ args: [path], command: "sh" }),
		]
	}
}

# -- TESTS --

target_cases = [
	{ arch: X64, os: LINUX, system: "x86_64-linux" },
	{ arch: AARCH64, os: LINUX, system: "aarch64-linux" },
	{ arch: X64, os: MACOS, system: "x86_64-darwin" },
	{ arch: AARCH64, os: MACOS, system: "aarch64-darwin" },
]

expect List.all(target_cases, |case| Nix.target(case.os, case.arch) == Ok({ system: case.system }))

validation_cases = [
	{
		expected: [],
		rules: Nix.package_rules,
		values: ["rocpkgs.nightly", "hello"],
	},
	{
		expected: [
			"shell package names must not be empty",
			"shell package attribute paths must not contain empty segments",
			"shell package attribute paths contain characters unsafe for Nix output",
		],
		rules: Nix.package_rules,
		values: ["", "rocpkgs..nightly", "hello$unsafe"],
	},
	{
		expected: [
			"shell overlay references must not be empty",
			"shell overlay references contain characters unsafe for Nix output",
		],
		rules: Nix.overlay_rules,
		values: ["", "github:example/overlay$unsafe"],
	},
]

expect List.all(
	validation_cases,
	|case| PluginApi.validate_string_list(case.values, case.rules) == case.expected,
)

expect Nix.locked_flake_templates == [
	WriteConfigUtf8({ output: "flake", path: ".kai/flake.nix" }),
	Exec({
		args: ["flake", "lock", "path:.kai", "--reference-lock-file", "kai.lock", "--output-lock-file", "kai.lock"],
		command: "nix",
	}),
	Exec({
		args: ["flake", "lock", "path:.kai", "--reference-lock-file", "kai.lock", "--output-lock-file", ".kai/flake.lock"],
		command: "nix",
	}),
]

expect Nix.shell_templates.drop_first(3) == [
	Exec({
		args: ["develop", "path:.kai#default", "--no-update-lock-file"],
		command: "nix",
	}),
]

expect Nix.build_templates.drop_first(3) == [
	WriteConfigUtf8({ output: "build_nix", path: ".kai/build.nix" }),
	WriteConfigUtf8({ output: "build_json", path: ".kai/build.json" }),
]

expect Nix.update_recipe == [
	WriteConfigUtf8({ output: "flake", path: ".kai/flake.nix" }),
	Exec({
		args: ["flake", "update", "--flake", "path:.kai", "--reference-lock-file", "kai.lock", "--output-lock-file", "kai.lock"],
		command: "nix",
	}),
	Exec({
		args: ["flake", "lock", "path:.kai", "--reference-lock-file", "kai.lock", "--output-lock-file", ".kai/flake.lock"],
		command: "nix",
	}),
]

expect Nix.named_artifact_actions("app") == [
	WriteUtf8({ content: "", path: ".kai/artifacts/.keep" }),
	Exec({ args: ["build", "--file", ".kai/build.nix", "--out-link", ".kai/artifacts/app"], command: "nix" }),
]

expect Nix.task_actions(["zig", "build"]) == [
	Exec({
		args: ["develop", "path:.kai#default", "--no-update-lock-file", "--command", "zig", "build"],
		command: "nix",
	}),
]

expect Nix.deploy_actions("production", "script") == [
	WriteUtf8({ content: "script", path: ".kai/deployments/production.sh" }),
	Exec({ args: [".kai/deployments/production.sh"], command: "sh" }),
]
