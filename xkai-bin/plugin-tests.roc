app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	commands: "../plugins/commands/main.roc",
	implementations: "../plugins/implementations/main.roc",
	kai: "./package.roc",
	std: "../plugins/main.roc",
}

import kai.Body
import kai.Plugin as PluginApi
import kai.Registry
import commands.Shell as ShellCommand
import implementations.ShellNix
import std.StdPlugin

Fixtures := [].{
	context : PluginApi.RenderContext
	context = PluginApi.RenderContext.{
		args: [],
		config: Body.empty,
		host_arch: X64,
		host_os: LINUX,
		source: NoSource,
	}

	empty_result = PluginApi.RenderResult.{ outputs: [], requested_packages: [] }

	empty_renderer : PluginApi.Renderer
	empty_renderer = |_| Ok(Fixtures.empty_result)

	multiple_result = PluginApi.RenderResult.{
		outputs: [
			{ name: "first", text: "one" },
			{ name: "second", text: "two" },
		],
		requested_packages: [],
	}

	multiple_renderer : PluginApi.Renderer
	multiple_renderer = |_| Ok(Fixtures.multiple_result)

	backend : Str, PluginApi.DeterminateSystemKind, [NoDriver, Program(Str)], Str, List(PluginApi.Package) -> PluginApi.Backend
	backend = |name, kind, driver, package_source, required_packages|
		PluginApi.Backend.{
			determinate_system: PluginApi.DeterminateSystem.{
				default_package_source: package_source,
				driver,
				kind,
			},
			fallback: NoFallback,
			name,
			required_packages,
		}

	nix = Fixtures.backend("nix", Nix, Program("nix"), "nixpkgs", [])

	guix = Fixtures.backend("guix", Guix, Program("guix"), "guix", [])

	custom = Fixtures.backend(
		"custom",
		Custom,
		Program("custom-driver"),
		"custom-packages",
		[PluginApi.Package.{ name: "formatter", program: "fmt" }],
	)

	local = Fixtures.backend("local", Custom, NoDriver, "local", [])

	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: AllowArguments,
		body: Body.object([]),
		default_backend: nix.name,
		name: "example",
		source: OptionalSource("example-config"),
	}

	implementation : Str, PluginApi.Renderer -> PluginApi.Implementation
	implementation = |backend_name, renderer|
		PluginApi.Implementation.{
			actions: [],
			backend: backend_name,
			command: command.name,
			renderer,
		}

	definition : PluginApi.Definition
	definition = PluginApi.Definition.{
		backends: [nix, guix, custom, local],
		commands: [command],
		implementations: [
			Fixtures.implementation(nix.name, Fixtures.empty_renderer),
			Fixtures.implementation(guix.name, Fixtures.multiple_renderer),
			Fixtures.implementation(custom.name, Fixtures.multiple_renderer),
			Fixtures.implementation(local.name, Fixtures.empty_renderer),
		],
		name: "minimal",
	}

	multiple_writes : PluginApi.Implementation
	multiple_writes = PluginApi.Implementation.{
		actions: [
			WriteConfigUtf8({ output: "first", path: "first.txt" }),
			WriteConfigUtf8({ output: "second", path: "second.txt" }),
		],
		backend: local.name,
		command: command.name,
		renderer: Fixtures.multiple_renderer,
	}

	missing_write : PluginApi.Implementation
	missing_write = PluginApi.Implementation.{
		actions: [WriteConfigUtf8({ output: "missing", path: "missing.txt" })],
		backend: local.name,
		command: command.name,
		renderer: Fixtures.multiple_renderer,
	}

	body_shape : Body.Shape
	body_shape = Body.object([
		Body.required("pkgs", StringList),
		Body.optional("description", String),
	])

	has_diagnostic : Str, U64, Body.DiagnosticKind -> Bool
	has_diagnostic = |source, byte_offset, kind|
		Body.parse(body_shape, source) == Err({ byte_offset, kind })

	RenderCase : {
		arch : PluginApi.HostArch,
		os : PluginApi.HostOs,
		pkgs : List(Str),
		source : Str,
		system : Str,
	}

	standard_context : Body.Configuration, Str, PluginApi.HostOs, PluginApi.HostArch -> PluginApi.RenderContext
	standard_context = |config, source, os, arch|
		PluginApi.RenderContext.{
			args: [],
			config,
			host_arch: arch,
			host_os: os,
			source: SelectedSource({
				body: source,
				location: { byte_offset: 0, column: 1, line: 1 },
			}),
		}

	render_standard : Str, PluginApi.HostOs, PluginApi.HostArch -> Try(PluginApi.RenderResult, Str)
	render_standard = |source, os, arch| {
		config = Body.parse(ShellCommand.body, source) ? |_| "invalid shell body"
		rendered = ShellNix.renderer(Fixtures.standard_context(config, source, os, arch)) ? |diagnostic| diagnostic.message
		Ok(rendered)
	}

	packages_rendered : Str, Str, List(Str) -> Bool
	packages_rendered = |text, system, pkgs|
		match pkgs {
			[] => Bool.True
			[first, .. as rest] => {
				expected = "              nixpkgs.\"legacyPackages\".\"${system}\".\"${first}\""
				match text.find_first(expected) {
					Err(NotFound) => Bool.False
					Ok({ after, before: _ }) => Fixtures.packages_rendered(after, system, rest)
				}
			}
		}

	render_cases : List(RenderCase) -> Bool
	render_cases = |cases|
		match cases {
			[] => Bool.True
			[first, .. as rest] =>
				match Fixtures.render_standard(first.source, first.os, first.arch) {
					Err(_) => Bool.False
					Ok({ outputs, requested_packages }) =>
						match outputs {
							[{ name, text }] =>
								name == "flake" and
									requested_packages == first.pkgs and
										text.contains("devShells.\"${first.system}\"") and
											(
												if first.pkgs.is_empty() {
													!text.contains("              nixpkgs.\"legacyPackages\"")
												} else {
													Bool.True
												},
											) and
												Fixtures.packages_rendered(text, first.system, first.pkgs) and
													Fixtures.render_cases(rest)
							_ => Bool.False
						}
					}
			}

	plan_contains : Str, PluginApi.HostOs, PluginApi.HostArch, Str -> Bool
	plan_contains = |source, os, arch, expected|
		match StdPlugin.plan(source, ["shell"], os, arch) {
			Ok({ actions: [WriteUtf8({ content, path: _ }), Exec(_)] }) => content.contains(expected)
			_ => Bool.False
		}
}

Validation := [].{
	field : Str -> Body.Field
	field = |name| Body.required(name, String)

	command : Str, Str, List(Body.Field) -> PluginApi.Command
	command = |name, default_backend, fields|
		PluginApi.Command.{
			argument_policy: NoArguments,
			body: Body.object(fields),
			default_backend,
			name,
			source: OptionalSource("validation"),
		}

	backend :
		Str,
		[NoDriver, Program(Str)],
		List(PluginApi.Package) ->
			PluginApi.Backend
	backend = |name, driver, required_packages|
		PluginApi.Backend.{
			determinate_system: PluginApi.DeterminateSystem.{
				default_package_source: "packages",
				driver,
				kind: Custom,
			},
			fallback: NoFallback,
			name,
			required_packages,
		}

	implementation : Str, Str -> PluginApi.Implementation
	implementation = |command_name, backend_name|
		PluginApi.Implementation.{
			actions: [],
			backend: backend_name,
			command: command_name,
			renderer: Fixtures.empty_renderer,
		}

	plugin :
		Str,
		List(PluginApi.Command),
		List(PluginApi.Backend),
		List(PluginApi.Implementation) ->
			PluginApi.Plugin
	plugin = |name, commands, backends, implementations|
		PluginApi.Plugin.Registry({
			definition: PluginApi.Definition.{
				backends,
				commands,
				implementations,
				name,
			},
		})

	valid : Str -> PluginApi.Plugin
	valid = |name|
		Validation.plugin(
			name,
			[Validation.command("run", "one", [Validation.field("field_1")])],
			[
				Validation.backend(
					"one",
					Program("driver"),
					[
						PluginApi.Package.{
							name: "pkg",
							program: "program",
						},
					],
				),
			],
			[Validation.implementation("run", "one")],
		)

	has_diagnostic : List(Str), Str -> Bool
	has_diagnostic = |diagnostics, expected|
		match diagnostics {
			[] => Bool.False
			[first, .. as rest] => first.contains(expected) or
				Validation.has_diagnostic(rest, expected)
		}

	all_cases_pass : List(
		{
			expected : Str,
			plugin : PluginApi.Plugin,
		},
	) -> Bool
	all_cases_pass = |cases|
		match cases {
			[] => Bool.True
			[first, .. as rest] => {
				diagnostics = Registry.validate([first.plugin])
				Validation.has_diagnostic(diagnostics, first.expected) and
					Validation.all_cases_pass(rest)
			}
		}
}

main! = |_| Ok({})

expect {
	good_command = Validation.command("run", "one", [Validation.field("field")])
	good_backend = Validation.backend("one", Program("driver"), [])
	good_implementation = Validation.implementation("run", "one")
	Validation.all_cases_pass([
		{ expected: "plugin name must not be empty", plugin: Validation.plugin("", [good_command], [good_backend], [good_implementation]) },
		{ expected: "at least one command", plugin: Validation.plugin("case", [], [good_backend], [good_implementation]) },
		{ expected: "at least one backend", plugin: Validation.plugin("case", [good_command], [], [good_implementation]) },
		{ expected: "at least one implementation", plugin: Validation.plugin("case", [good_command], [good_backend], []) },
		{ expected: "command name must not be empty", plugin: Validation.plugin("case", [Validation.command("", "one", [])], [good_backend], [Validation.implementation("", "one")]) },
		{ expected: "backend name must not be empty", plugin: Validation.plugin("case", [Validation.command("run", "", [])], [Validation.backend("", NoDriver, [])], [Validation.implementation("run", "")]) },
		{ expected: "field name must not be empty", plugin: Validation.plugin("case", [Validation.command("run", "one", [Validation.field("")])], [good_backend], [good_implementation]) },
		{ expected: "package name must not be empty", plugin: Validation.plugin("case", [good_command], [Validation.backend("one", NoDriver, [PluginApi.Package.{ name: "", program: "program" }])], [good_implementation]) },
		{ expected: "program name must not be empty", plugin: Validation.plugin("case", [good_command], [Validation.backend("one", NoDriver, [PluginApi.Package.{ name: "pkg", program: "" }])], [good_implementation]) },
		{ expected: "driver name must not be empty", plugin: Validation.plugin("case", [good_command], [Validation.backend("one", Program(""), [])], [good_implementation]) },
		{ expected: "duplicate command 'run'", plugin: Validation.plugin("case", [good_command, good_command], [good_backend], [good_implementation]) },
		{ expected: "duplicate backend 'one'", plugin: Validation.plugin("case", [good_command], [good_backend, good_backend], [good_implementation]) },
		{ expected: "duplicate implementation 'run/one'", plugin: Validation.plugin("case", [good_command], [good_backend], [good_implementation, good_implementation]) },
		{ expected: "unknown command 'missing'", plugin: Validation.plugin("case", [good_command], [good_backend], [Validation.implementation("missing", "one")]) },
		{ expected: "unknown backend 'missing'", plugin: Validation.plugin("case", [good_command], [good_backend], [Validation.implementation("run", "missing")]) },
		{ expected: "command 'unused' has no implementation", plugin: Validation.plugin("case", [good_command, Validation.command("unused", "one", [])], [good_backend], [good_implementation]) },
		{ expected: "backend 'unused' has no implementation", plugin: Validation.plugin("case", [good_command], [good_backend, Validation.backend("unused", NoDriver, [])], [good_implementation]) },
		{ expected: "default backend 'missing' does not exist", plugin: Validation.plugin("case", [Validation.command("run", "missing", [])], [good_backend], [good_implementation]) },
		{ expected: "does not implement the command", plugin: Validation.plugin("case", [good_command], [good_backend, Validation.backend("two", NoDriver, [])], [Validation.implementation("run", "two")]) },
		{ expected: "duplicate field 'field'", plugin: Validation.plugin("case", [Validation.command("run", "one", [Validation.field("field"), Validation.field("field")])], [good_backend], [good_implementation]) },
		{ expected: "must match [A-Za-z_]", plugin: Validation.plugin("case", [Validation.command("run", "one", [Validation.field("9field")])], [good_backend], [good_implementation]) },
		{ expected: "must match [A-Za-z_]", plugin: Validation.plugin("case", [Validation.command("run", "one", [Validation.field("field☃")])], [good_backend], [good_implementation]) },
	])
}

expect {
	plugin = Validation.plugin(
		"case",
		[Validation.command("run", "one", [Validation.field("")])],
		[Validation.backend("one", NoDriver, [])],
		[Validation.implementation("run", "one")],
	)
	Registry.validate([plugin]) == [
		"plugin 'case': command 'run' field name must not be empty",
	]
}

expect {
	plugin = Validation.plugin(
		"case",
		[Validation.command("run", "one", []), Validation.command("run", "one", [])],
		[Validation.backend("one", NoDriver, [])],
		[],
	)
	Registry.validate([plugin]) == [
		"plugin 'case': must define at least one implementation",
		"plugin 'case': duplicate command 'run'",
		"plugin 'case': command 'run' has no implementation",
		"plugin 'case': backend 'one' has no implementation",
		"plugin 'case': command 'run' default backend 'one' does not implement the command",
	]
}

expect {
	plugin = Validation.plugin(
		"multi",
		[Validation.command("run", "one", [])],
		[Validation.backend("one", NoDriver, []), Validation.backend("two", NoDriver, [])],
		[Validation.implementation("run", "one"), Validation.implementation("run", "two")],
	)
	Registry.validate([plugin]) == []
}

expect Registry.validate([Validation.valid("first"), Validation.valid("second")]) == []

expect {
	diagnostics = Registry.validate([Validation.plugin("", [], [], []), Validation.plugin("second", [], [], [])])
	diagnostics.len() == 7 and
		diagnostics.map(|message| message.starts_with("plugin #1:")).keep_if(|prefixed| prefixed).len() == 4 and
			diagnostics.map(|message| message.starts_with("plugin 'second':")).keep_if(|prefixed| prefixed).len() == 3
}

expect {
	Fixtures.render_cases([
		{ arch: X64, os: LINUX, pkgs: [], source: "pkgs: []", system: "x86_64-linux" },
		{ arch: AARCH64, os: LINUX, pkgs: ["cowsay"], source: "pkgs: [\"cowsay\"]", system: "aarch64-linux" },
		{ arch: X64, os: MACOS, pkgs: ["cowsay", "fortune"], source: "pkgs: [\"cowsay\", \"fortune\"]", system: "x86_64-darwin" },
		{ arch: AARCH64, os: MACOS, pkgs: ["fortune"], source: "pkgs: [\"fortune\"]", system: "aarch64-darwin" },
	])
}

expect {
	Body.parse(ShellCommand.body, "pkgs: \"cowsay\"") == Err({
		byte_offset: 6,
		kind: WrongType({ expected: StringList, field: "pkgs" }),
	}) and
		Body.parse(ShellCommand.body, "") == Err({ byte_offset: 0, kind: MissingField("pkgs") })
}

expect {
	definition = StdPlugin.definition
	definition.name == "std" and
		definition.commands.len() == 1 and
			definition.backends.len() == 1 and
				definition.implementations.len() == 1
}

expect ShellNix.renderer(Fixtures.standard_context(Body.empty, "pkgs: []", LINUX, X64)) == Err({
	byte_offset: None,
	message: "validated shell configuration is missing 'pkgs'",
})

expect Fixtures.render_standard("pkgs: [\"\"]", LINUX, X64) == Err("shell package names must not be empty")

expect Fixtures.render_standard("pkgs: []", OTHER("unsupported"), X64) == Err("unsupported shell platform")

expect Fixtures.plan_contains("shell {\n  pkgs: [\"cowsay\"]\n}", LINUX, X64, ".\"cowsay\"")

expect {
	source = "on linux {\n  shell {\n    pkgs: [\"cowsay\"]\n  }\n}\non macos {\n  shell {\n    pkgs: [\"fortune\"]\n  }\n}"
	Fixtures.plan_contains(source, MACOS, AARCH64, ".\"fortune\"")
}

expect {
	plugin = PluginApi.Plugin.Registry({ definition: Fixtures.definition })
	definition = PluginApi.definition(plugin)
	definition.name == "minimal" and
		definition.commands.len() == 1 and
			definition.backends.len() == 4 and
				definition.implementations.len() == 4
}

expect PluginApi.lower(Fixtures.multiple_writes, Fixtures.multiple_result) == Ok(
	PluginApi.Plan.{
		actions: [
			WriteUtf8({ content: "one", path: "first.txt" }),
			WriteUtf8({ content: "two", path: "second.txt" }),
		],
	},
)

expect Fixtures.empty_renderer(Fixtures.context) == Ok(Fixtures.empty_result)

expect PluginApi.lower(Fixtures.missing_write, Fixtures.multiple_result) == Err({
	byte_offset: None,
	message: "plugin renderer did not return named output 'missing'",
})

expect {
	source = " # before\n pkgs: [\n  \"cowsay\", # package\n  \"fortune\"\n ]\n description: \"# kept\" # after\n"
	match Body.parse(Fixtures.body_shape, source) {
		Err(_) => Bool.False
		Ok(config) =>
			Body.get_strings(config, "pkgs") == Ok(["cowsay", "fortune"]) and
				Body.get_string(config, "description") == Ok("# kept")
		}
}

expect {
	config = Body.parse(Fixtures.body_shape, "pkgs: []")?
	Body.get_strings(config, "pkgs") == Ok([]) and
		Body.maybe_string(config, "description") == Ok(None) and
			Body.get_string(config, "description") == Err(MissingField("description")) and
				Body.get_string(config, "pkgs") == Err(WrongType({ expected: String, field: "pkgs" }))
}

expect Fixtures.has_diagnostic(
	"pkgs: []\n  pkgs: []",
	11,
	DuplicateField("pkgs"),
)

expect Fixtures.has_diagnostic(
	"# ☃\nextra: \"x\"",
	6,
	UnknownField("extra"),
)

expect Fixtures.has_diagnostic(
	"pkgs: \"not a list\"",
	6,
	WrongType({ expected: StringList, field: "pkgs" }),
)

expect Fixtures.has_diagnostic(
	"pkgs: [\"ok\", 3]",
	13,
	WrongListItem("pkgs"),
)

expect Fixtures.has_diagnostic(
	"pkgs: []\ndescription: \"\\q\"",
	22,
	InvalidString("invalid string"),
)

expect Fixtures.has_diagnostic(
	"pkgs: [",
	7,
	InvalidSyntax("unterminated list in field 'pkgs'"),
)

expect Fixtures.has_diagnostic(
	"pkgs: [\"one\" \"two\"]",
	13,
	InvalidSyntax("expected ',' or ']' in field 'pkgs'"),
)

expect Fixtures.has_diagnostic(
	"pkgs []",
	5,
	InvalidSyntax("expected ':' after field 'pkgs'"),
)

expect Fixtures.has_diagnostic("", 0, MissingField("pkgs"))

expect {
	config = Body.parse(Fixtures.body_shape, "pkgs: []\ndescription: \"line\\nnext\"")?
	Body.get_string(config, "description") == Ok("line\nnext")
}
