import parser.Body
import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Build as BuildCommand
import ShellNix

BuildNix := [].{
	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: NixBackend.build_templates,
		backend: NixBackend.backend.name,
		command: BuildCommand.command.name,
		renderer: BuildNix.renderer,
	}

	renderer : PluginApi.Renderer
	renderer = |context| {
		name = match context.args {
			[selected_name] => Ok(selected_name)
			# `kai build nix` selects the Nix backend before the standard selector
			# recognizes the colliding artifact name.
			[] => Ok(NixBackend.backend.name)
			_ => Err({ byte_offset: None, message: "build requires exactly one artifact name" })
		}?
		name_failures = PluginApi.validate_text(name, BuildCommand.artifact_name_rules)
		run = Body.get_strings(context.config, "run") ? |_| {
			byte_offset: None,
			message: "validated build configuration is missing 'run'",
		}
		run_failures = PluginApi.validate_string_list(run, BuildCommand.run_rules)
		output = Body.get_string(context.config, "output") ? |_| {
			byte_offset: None,
			message: "validated build configuration is missing 'output'",
		}
		output_failures = PluginApi.validate_text(output, BuildCommand.output_rules)
		PluginApi.renderer_validation(name_failures.concat(run_failures).concat(output_failures))?
		environment = match context.related_config {
			NoRelatedConfig => Err({ byte_offset: None, message: "build environment is required" })
			SelectedRelatedConfig({ block: _, config }) => Ok(config)
		}?
		pkgs = Body.get_strings(environment, "packages") ? |_| {
			byte_offset: None,
			message: "validated environment configuration is missing 'packages'",
		}
		PluginApi.renderer_validation(PluginApi.validate_string_list(pkgs, NixBackend.package_rules))?
		target = NixBackend.target(context.host_os, context.host_arch) ? |_|
			{ byte_offset: None, message: "unsupported build platform" }
		Ok(
			PluginApi.RenderResult.{
				actions: NixBackend.named_artifact_actions(name),
				outputs: [
					{ name: "flake", text: ShellNix.render_nix(pkgs, [], target.system) },
					{ name: "build_nix", text: BuildNix.nix_expression },
					{
						name: "build_json",
						text: Json.to_str({ name, output, pkgs, run, system: target.system }),
					},
				],
				requests: [],
				requested_packages: pkgs,
			},
		)
	}

	nix_expression : Str
	nix_expression = Str.join_with(
		[
			"let",
			"  config = builtins.fromJSON (builtins.readFile ./build.json);",
			"  flake = builtins.getFlake (toString ./.);",
			"  pkgs = builtins.getAttr config.system flake.inputs.nixpkgs.legacyPackages;",
			"  lib = pkgs.lib;",
			"  resolvePackage = name:",
			"    lib.attrByPath (lib.splitString \".\" name)",
			"      (throw (\"Kai build package '\" + name + \"' was not found\"))",
			"      pkgs;",
			"  source = pkgs.nix-gitignore.gitignoreFilterRecursiveSource",
			"    (_: _: true) \".git\\n.kai\" ../.;",
			"in",
			"pkgs.runCommand (\"kai-build-\" + config.name)",
			"  { nativeBuildInputs = map resolvePackage config.pkgs; }",
			"  ''",
			Str.join_with(["    cp -R ", BuildNix.nix_interpolation("source"), "/. ."], ""),
			"    chmod -R u+w .",
			Str.join_with(["    artifact=", BuildNix.nix_interpolation("lib.escapeShellArg config.output")], ""),
			"    rm -rf -- \"$artifact\"",
			Str.join_with(["    ", BuildNix.nix_interpolation("lib.escapeShellArgs config.run")], ""),
			"    if [ ! -e \"$artifact\" ]; then",
			"      echo \"Kai build output does not exist: $artifact\" >&2",
			"      exit 1",
			"    fi",
			"    if [ -d \"$artifact\" ]; then",
			"      cp -R -- \"$artifact\" \"$out\"",
			"    else",
			"      cp -- \"$artifact\" \"$out\"",
			"    fi",
			"  ''",
		],
		"\n",
	)

	nix_interpolation : Str -> Str
	nix_interpolation = |expression| Str.join_with(["$", "{", expression, "}"], "")

}

# -- TESTS --

name_cases = [
	{ expected: [], name: "app" },
	{ expected: [], name: "web.app_1-release" },
	{ expected: ["artifact name must not be empty"], name: "" },
	{
		expected: ["artifact name must not start with '.'"],
		name: ".",
	},
	{
		expected: ["artifact name must not start with '.'"],
		name: "..",
	},
	{
		expected: ["artifact name must not start with '.'"],
		name: ".keep",
	},
	{
		expected: ["artifact name may contain only ASCII letters, digits, '.', '_', and '-'"],
		name: "nested/app",
	},
	{
		expected: ["artifact name may contain only ASCII letters, digits, '.', '_', and '-'"],
		name: "app name",
	},
]

expect List.all(
	name_cases,
	|case| PluginApi.validate_text(case.name, BuildCommand.artifact_name_rules) == case.expected,
)

run_cases = [
	{ expected: [], run: ["zig", "build"] },
	{ expected: ["build run list must not be empty"], run: [] },
	{ expected: ["build run program must not be empty"], run: [""] },
]

expect List.all(
	run_cases,
	|case| PluginApi.validate_string_list(case.run, BuildCommand.run_rules) == case.expected,
)

output_cases = [
	{ expected: [], output: "zig-out/bin/app" },
	{ expected: [], output: "output with spaces" },
	{
		expected: ["build output must not be empty"],
		output: "",
	},
	{
		expected: ["build output must be relative"],
		output: "/tmp/app",
	},
	{
		expected: ["build output must not contain '.' or '..' path segments"],
		output: ".",
	},
	{
		expected: ["build output must not contain '.' or '..' path segments"],
		output: "zig-out/../app",
	},
]

expect List.all(
	output_cases,
	|case| PluginApi.validate_text(case.output, BuildCommand.output_rules) == case.expected,
)

expect PluginApi.renderer_validation(
	PluginApi.validate_string_list([], BuildCommand.run_rules).concat(
		PluginApi.validate_text("/../app", BuildCommand.output_rules),
	),
) == Err({
	byte_offset: None,
	message: \\build run list must not be empty
		\\\nbuild output must be relative
		\\\nbuild output must not contain '.' or '..' path segments",
	,
})

encoded_config = Json.to_str({
	name: "app",
	output: "out/$artifact's file",
	pkgs: ["hello"],
	run: ["printf", "%s\\n", "a '$value'"],
	system: "x86_64-linux",
})

expect encoded_config == "{\"name\":\"app\",\"output\":\"out/$artifact's file\",\"pkgs\":[\"hello\"],\"run\":[\"printf\",\"%s\\\\n\",\"a '$value'\"],\"system\":\"x86_64-linux\"}"

parsed_build = Body.parse(
	BuildCommand.body,
	"environment: dev\nrun: [\"zig\", \"build\"]\noutput: \"zig-out/bin/app\"",
)

expect match parsed_build {
	Ok(config) => Body.get_string(config, "environment") == Ok("dev")
	Err(_) => Bool.False
}

expect match parsed_build {
	Err(_) => Bool.False
	Ok(config) =>
		match Body.parse(Body.object([Body.required("packages", StringList)]), "packages: [\"zig\"]") {
			Err(_) => Bool.False
			Ok(environment) =>
				match BuildNix.renderer({
					args: ["app"],
					config,
					config_block: NoConfigBlock,
					host_arch: X64,
					host_os: LINUX,
					related_config: SelectedRelatedConfig({
						block: {
							body: "packages: [\"zig\"]",
							location: { byte_offset: 0, column: 1, line: 1 },
						},
						config: environment,
					}),
				}) {
					Err(_) => Bool.False
					Ok(rendered) =>
						match rendered.actions {
							[WriteUtf8(marker), Exec(exec)] =>
								marker.path == ".kai/artifacts/.keep" and
									exec.command == "nix" and
										exec.args == [
											"build",
											"--file",
											".kai/build.nix",
											"--out-link",
											".kai/artifacts/app",
										]
							_ => Bool.False
						}
					}
			}
	}
