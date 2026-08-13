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
}

# -- TESTS --

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
