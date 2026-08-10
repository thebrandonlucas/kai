app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	commands: "../plugins/commands/main.roc",
	implementations: "../plugins/implementations/main.roc",
	kai: "./package.roc",
	parser: "./parser/main.roc",
	std: "../plugins/main.roc",
}

import parser.Body
import parser.Config
import kai.Plugin as PluginApi
import commands.Shell as ShellCommand
import implementations.ShellNix
import std.StdPlugin

Fixtures := [].{
	context : PluginApi.RenderContext
	context = PluginApi.RenderContext.{
		args: [],
		config: Body.empty,
		config_block: NoConfigBlock,
		host_arch: X64,
		host_os: LINUX,
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
		config_block: OptionalConfigBlock("example-config"),
		default_backend: nix.name,
		name: "example",
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
	has_diagnostic = |body_text, byte_offset, kind|
		Body.parse(body_shape, body_text) == Err({ byte_offset, kind })

	RenderCase : {
		arch : PluginApi.HostArch,
		body_text : Str,
		os : PluginApi.HostOs,
		pkgs : List(Str),
		system : Str,
	}

	standard_context : Body.Configuration, Str, PluginApi.HostOs, PluginApi.HostArch -> PluginApi.RenderContext
	standard_context = |config, body_text, os, arch|
		PluginApi.RenderContext.{
			args: [],
			config,
			config_block: SelectedConfigBlock({
				body: body_text,
				location: { byte_offset: 0, column: 1, line: 1 },
			}),
			host_arch: arch,
			host_os: os,
		}

	render_standard : Str, PluginApi.HostOs, PluginApi.HostArch -> Try(PluginApi.RenderResult, Str)
	render_standard = |body_text, os, arch| {
		config = Body.parse(ShellCommand.body, body_text) ? |_| "invalid shell body"
		rendered = ShellNix.renderer(Fixtures.standard_context(config, body_text, os, arch)) ? |diagnostic| diagnostic.message
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
				match Fixtures.render_standard(first.body_text, first.os, first.arch) {
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

	select_missing : PluginApi.ConfigSelector
	select_missing = |_, _, _, _, _| Ok(Missing)

	# FIX confused by the purpose of Body.object why do we need that
	registry_body = Body.object(
		[Body.required("value", String)],
	)

	registry_command : PluginApi.Command
	registry_command = PluginApi.Command.{
		argument_policy: NoArguments,
		# ???
		body: registry_body,
		# ???
		config_block: RequiredConfigBlock("fixture"),
		default_backend: nix.name,
		name: "registry-command",
	}

	registry_renderer : PluginApi.Renderer
	registry_renderer = |selected_context| {
		value = Body.get_string(selected_context.config, "value") ? |_| {
			byte_offset: None,
			message: "value missing after validation",
		}
		Ok(
			PluginApi.RenderResult.{
				outputs: [{ name: "selected", text: value }],
				requested_packages: ["requested"],
			},
		)
	}

	optional_renderer : PluginApi.Renderer
	optional_renderer = |selected_context|
		match selected_context.config_block {
			NoConfigBlock =>
				if selected_context.config == Body.empty {
					Ok(
						PluginApi.RenderResult.{
							outputs: [{ name: "selected", text: "empty" }],
							requested_packages: [],
						},
					)
				} else {
					Err({ byte_offset: None, message: "expected empty config" })
				}
			SelectedConfigBlock(_) => Err({ byte_offset: None, message: "expected no config block" })
		}

	registry_definition : Str, PluginApi.Command, PluginApi.Renderer -> PluginApi.RegistryDefinition
	registry_definition = |name, selected_command, renderer| {
		make_implementation = |backend_name| PluginApi.Implementation.{
			actions: [
				WriteConfigUtf8({ output: "selected", path: "selected.txt" }),
				Exec({ args: ["run"], command: "driver" }),
			],
			backend: backend_name,
			command: selected_command.name,
			renderer,
		}
		{
			definition: PluginApi.Definition.{
				backends: [nix, guix],
				commands: [selected_command],
				implementations: [make_implementation(nix.name), make_implementation(guix.name)],
				name,
			},
			select_config: Fixtures.registry_selector,
		}
	}

	registry_selector : PluginApi.ConfigSelector
	registry_selector = |raw_config, selected_command, backend_choice, _os, _arch| {
		block_name = match selected_command.config_block {
			OptionalConfigBlock(name) => name
			RequiredConfigBlock(name) => name
		}
		backend_header = match backend_choice {
			DefaultBackend(selected_backend) => [block_name, "default", selected_backend.name]
			ExplicitBackend(selected_backend) => [block_name, "explicit", selected_backend.name]
		}
		# This fixture plugin owns all header meanings; the planner only passes data.
		blocks = Config.scan(raw_config) ? |diagnostic| {
			location: At(Fixtures.source_location(diagnostic.location)),
			message: "invalid fixture config",
		}
		selection = Config.select_exact(blocks, backend_header) ? |_| {
			location: None,
			message: "duplicate fixture config",
		}
		match selection {
			Missing => Ok(Missing)
			Selected(block) => Ok(
				Selected({
					body: block.body,
					location: Fixtures.source_location(block.location),
				}),
			)
		}
	}

	source_location : Config.Location -> PluginApi.SourceLocation
	source_location = |location| {
		byte_offset: location.byte_offset,
		column: location.column,
		line: location.line,
	}

	plan_registry : List(PluginApi.RegistryDefinition), Str, List(Str) -> Try(PluginApi.Plan, PluginApi.Error)
	plan_registry = |registry, config, args| PluginApi.plan_registry(registry, config, args, LINUX, X64)

	plan_contains : Str, PluginApi.HostOs, PluginApi.HostArch, Str -> Bool
	plan_contains = |config_text, os, arch, expected|
		match PluginApi.plan_registry([StdPlugin.plugin], config_text, ["shell"], os, arch) {
			Ok(
				{
					actions: [WriteUtf8({ content, path: _ }), Exec(_)],
					backend: _,
					command: _,
					plugin: _,
					requested_packages: _,
				},
			) => content.contains(expected)
			_ => Bool.False
		}
}

main! = |_| Ok({})

# Inputs -> expected generated target and packages:
# pkgs: [] on Linux/x64 -> x86_64-linux with no packages
# pkgs: ["cowsay"] on Linux/Arm64 -> aarch64-linux with cowsay
# pkgs: ["cowsay", "fortune"] on macOS/x64 -> x86_64-darwin with cowsay and fortune
# pkgs: ["fortune"] on macOS/Arm64 -> aarch64-darwin with fortune
expect {
	Fixtures.render_cases([
		{ arch: X64, body_text: "pkgs: []", os: LINUX, pkgs: [], system: "x86_64-linux" },
		{ arch: AARCH64, body_text: "pkgs: [\"cowsay\"]", os: LINUX, pkgs: ["cowsay"], system: "aarch64-linux" },
		{ arch: X64, body_text: "pkgs: [\"cowsay\", \"fortune\"]", os: MACOS, pkgs: ["cowsay", "fortune"], system: "x86_64-darwin" },
		{ arch: AARCH64, body_text: "pkgs: [\"fortune\"]", os: MACOS, pkgs: ["fortune"], system: "aarch64-darwin" },
	])
}

# Input: pkgs: "cowsay" -> WrongType(StringList, "pkgs") at byte 6
# Input: <empty> -> MissingField("pkgs") at byte 0
expect {
	Body.parse(ShellCommand.body, "pkgs: \"cowsay\"") == Err({
		byte_offset: 6,
		kind: WrongType({ expected: StringList, field: "pkgs" }),
	}) and Body.parse(ShellCommand.body, "") == Err({ byte_offset: 0, kind: MissingField("pkgs") })
}

# Expected definition: name "std" with one command, backend, and implementation
expect {
	definition = StdPlugin.definition
	definition.name == "std" and
		definition.commands.len() == 1 and
			definition.backends.len() == 1 and
				definition.implementations.len() == 1
}

# Input: empty validated config -> error "validated shell configuration is missing 'pkgs'"
expect ShellNix.renderer(Fixtures.standard_context(Body.empty, "pkgs: []", LINUX, X64)) == Err({
	byte_offset: None,
	message: "validated shell configuration is missing 'pkgs'",
})

# Input: pkgs: [""] -> error "shell package names must not be empty"
expect Fixtures.render_standard("pkgs: [\"\"]", LINUX, X64) == Err("shell package names must not be empty")

# Input: pkgs: [] on unsupported OS -> error "unsupported shell platform"
expect Fixtures.render_standard("pkgs: []", OTHER("unsupported"), X64) == Err("unsupported shell platform")

# Input:
# shell {
#   pkgs: ["cowsay"]
# }
# Expected generated flake to contain: ."cowsay"
expect Fixtures.plan_contains("shell {\n  pkgs: [\"cowsay\"]\n}", LINUX, X64, ".\"cowsay\"")

# Input selects pkgs: ["fortune"] from the macOS shell block.
# Expected generated flake to contain: ."fortune"
expect {
	config_text = "on linux {\n  shell {\n    pkgs: [\"cowsay\"]\n  }\n}\non macos {\n  shell {\n    pkgs: [\"fortune\"]\n  }\n}"
	Fixtures.plan_contains(config_text, MACOS, AARCH64, ".\"fortune\"")
}

# A host block without a shell ignores a wrong-host shell and falls back top-level.
expect {
	config_text = "on macos { shell { pkgs: [\"cowsay\"] } }\non linux { other { ignored } }\nshell { pkgs: [\"fortune\"] }"
	Fixtures.plan_contains(config_text, LINUX, X64, ".\"fortune\"")
}

# Explicit backend selection uses the backend-qualified command block.
expect {
	match PluginApi.select_config(
		"fixture guix {value: \"selected\"}",
		Fixtures.registry_command,
		ExplicitBackend(Fixtures.guix),
		LINUX,
		X64,
	) {
		Ok(Selected({ body, location: _ })) => body == "value: \"selected\""
		_ => Bool.False
	}
}

# Duplicate applicable blocks report the second block's body location.
expect PluginApi.select_config(
	"fixture {value: \"one\"}\nfixture {value: \"two\"}",
	Fixtures.registry_command,
	DefaultBackend(Fixtures.nix),
	LINUX,
	X64,
) == Err({
	location: At({ byte_offset: 32, column: 10, line: 2 }),
	message: "duplicate command configuration",
})

# Nested selector failures retain their absolute source location.
expect PluginApi.select_config(
	"on linux {\n  \"oops\"\n}",
	Fixtures.registry_command,
	DefaultBackend(Fixtures.nix),
	LINUX,
	X64,
) == Err({
	location: At({ byte_offset: 13, column: 3, line: 2 }),
	message: "invalid host configuration",
})

# Nested body failures retain their absolute source location and registry owner.
expect PluginApi.plan_registry(
	[StdPlugin.plugin],
	"on linux {\n  shell {\n    pkgs: \"cowsay\"\n  }\n}",
	["shell"],
	LINUX,
	X64,
) == Err(
	PlanningFailed({
		backend: "nix",
		command: "shell",
		location: At({ byte_offset: 31, column: 11, line: 3 }),
		message: "field 'pkgs' must be a list of strings",
		plugin: "std",
	}),
)

# Expected definition: name "minimal" with one command, four backends, and four implementations
expect {
	plugin : PluginApi.RegistryDefinition
	plugin = { definition: Fixtures.definition, select_config: Fixtures.select_missing }
	definition = plugin.definition
	definition.name == "minimal" and
		definition.commands.len() == 1 and
			definition.backends.len() == 4 and
				definition.implementations.len() == 4
}

# The first registry owning a command wins and its default backend is retained.
expect {
	first = Fixtures.registry_definition("first", Fixtures.registry_command, Fixtures.registry_renderer)
	second = Fixtures.registry_definition("second", Fixtures.registry_command, Fixtures.registry_renderer)
	match Fixtures.plan_registry(
		[first, second],
		"fixture default nix {value: \"first value\"}",
		[Fixtures.registry_command.name],
	) {
		Ok(plan) => plan.plugin == "first" and plan.backend == Fixtures.nix
		_ => Bool.False
	}
}

# A known backend argument is explicit, consumed, and retained with all plan data.
expect {
	registry = Fixtures.registry_definition("owner", Fixtures.registry_command, Fixtures.registry_renderer)
	match Fixtures.plan_registry(
		[registry],
		"fixture explicit guix {value: \"kept\"}",
		[Fixtures.registry_command.name, "guix"],
	) {
		Ok(plan) =>
			plan.plugin == "owner" and
				plan.command == Fixtures.registry_command.name and
					plan.backend == Fixtures.guix and
						plan.requested_packages == ["requested"] and
							plan.actions == [
								WriteUtf8({ content: "kept", path: "selected.txt" }),
								Exec({ args: ["run"], command: "driver" }),
							]
		_ => Bool.False
	}
}

# A missing required block identifies its owner and selected backend.
expect {
	registry = Fixtures.registry_definition("owner", Fixtures.registry_command, Fixtures.registry_renderer)
	Fixtures.plan_registry([registry], "", [Fixtures.registry_command.name]) == Err(
		PlanningFailed({
			backend: "nix",
			command: Fixtures.registry_command.name,
			location: None,
			message: "missing required config block 'fixture'",
			plugin: "owner",
		}),
	)
}

# A missing optional block reaches the renderer as Body.empty and NoConfigBlock.
expect {
	registry = Fixtures.registry_definition("optional-owner", Fixtures.command, Fixtures.optional_renderer)
	match Fixtures.plan_registry([registry], "", [Fixtures.command.name]) {
		Ok(plan) => plan.actions == [
			WriteUtf8({ content: "empty", path: "selected.txt" }),
			Exec({ args: ["run"], command: "driver" }),
		]
		_ => Bool.False
	}
}

# Body-relative failures are translated and identify plugin, command, and backend.
expect {
	registry = Fixtures.registry_definition("body-owner", Fixtures.registry_command, Fixtures.registry_renderer)
	Fixtures.plan_registry(
		[registry],
		"fixture default nix {\nvalue: []\n}",
		[Fixtures.registry_command.name],
	) == Err(
		PlanningFailed({
			backend: "nix",
			command: Fixtures.registry_command.name,
			location: At({ byte_offset: 29, column: 8, line: 2 }),
			message: "field 'value' must be a string",
			plugin: "body-owner",
		}),
	)
}

# Inputs: outputs first="one" and second="two"
# Expected writes: first.txt="one" and second.txt="two"
expect PluginApi.lower(
	Fixtures.multiple_writes,
	Fixtures.multiple_result,
	Fixtures.definition.name,
	Fixtures.local,
) == Ok(
	PluginApi.Plan.{
		actions: [
			WriteUtf8({ content: "one", path: "first.txt" }),
			WriteUtf8({ content: "two", path: "second.txt" }),
		],
		backend: Fixtures.local,
		command: Fixtures.command.name,
		plugin: Fixtures.definition.name,
		requested_packages: [],
	},
)

expect Fixtures.empty_renderer(Fixtures.context) == Ok(Fixtures.empty_result)

# Input requests missing output "missing" -> error "plugin renderer did not return named output 'missing'"
expect PluginApi.lower(
	Fixtures.missing_write,
	Fixtures.multiple_result,
	Fixtures.definition.name,
	Fixtures.local,
) == Err({
	byte_offset: None,
	message: "plugin renderer did not return named output 'missing'",
})

# Input contains comments around pkgs ["cowsay", "fortune"] and description "# kept".
# Expected output: pkgs ["cowsay", "fortune"] and description "# kept"
expect {
	body_text = " # before\n pkgs: [\n  \"cowsay\", # package\n  \"fortune\"\n ]\n description: \"# kept\" # after\n"
	match Body.parse(Fixtures.body_shape, body_text) {
		Err(_) => Bool.False
		Ok(config) =>
			Body.get_strings(config, "pkgs") == Ok(["cowsay", "fortune"]) and
				Body.get_string(config, "description") == Ok("# kept")
		}
}

# Input: pkgs: [] with no description
# Expected output: empty pkgs, optional description None, required access MissingField,
# and reading pkgs as String returns WrongType
expect {
	config = Body.parse(Fixtures.body_shape, "pkgs: []")?
	Body.get_strings(config, "pkgs") == Ok([]) and
		Body.maybe_string(config, "description") == Ok(None) and
			Body.get_string(config, "description") == Err(MissingField("description")) and
				Body.get_string(config, "pkgs") == Err(WrongType({ expected: String, field: "pkgs" }))
}

# Input:
# pkgs: []
# pkgs: []
# Expected: DuplicateField("pkgs") at byte 11
expect Fixtures.has_diagnostic(
	"pkgs: []\n  pkgs: []",
	11,
	DuplicateField("pkgs"),
)

# Input:
# # ☃
# extra: "x"
# Expected: UnknownField("extra") at byte 6
expect Fixtures.has_diagnostic(
	"# ☃\nextra: \"x\"",
	6,
	UnknownField("extra"),
)

# Input: pkgs: "not a list" -> WrongType(StringList, "pkgs") at byte 6
expect Fixtures.has_diagnostic(
	"pkgs: \"not a list\"",
	6,
	WrongType({ expected: StringList, field: "pkgs" }),
)

# Input: pkgs: ["ok", 3] -> WrongListItem("pkgs") at byte 13
expect Fixtures.has_diagnostic(
	"pkgs: [\"ok\", 3]",
	13,
	WrongListItem("pkgs"),
)

# Input: description: "\q" -> InvalidString("invalid string") at byte 22
expect Fixtures.has_diagnostic(
	"pkgs: []\ndescription: \"\\q\"",
	22,
	InvalidString("invalid string"),
)

# Input: pkgs: [ -> InvalidSyntax("unterminated list in field 'pkgs'") at byte 7
expect Fixtures.has_diagnostic(
	"pkgs: [",
	7,
	InvalidSyntax("unterminated list in field 'pkgs'"),
)

# Input: pkgs: ["one" "two"] -> InvalidSyntax("expected ',' or ']'") at byte 13
expect Fixtures.has_diagnostic(
	"pkgs: [\"one\" \"two\"]",
	13,
	InvalidSyntax("expected ',' or ']' in field 'pkgs'"),
)

# Input: pkgs [] -> InvalidSyntax("expected ':' after field 'pkgs'") at byte 5
expect Fixtures.has_diagnostic(
	"pkgs []",
	5,
	InvalidSyntax("expected ':' after field 'pkgs'"),
)

# Input: <empty> -> MissingField("pkgs") at byte 0
expect Fixtures.has_diagnostic("", 0, MissingField("pkgs"))

# Input: description contains the escaped newline in "line\nnext".
# Expected output:
# line
# next
expect {
	config = Body.parse(Fixtures.body_shape, "pkgs: []\ndescription: \"line\\nnext\"")?
	Body.get_string(config, "description") == Ok("line\nnext")
}

# Exact ordered headers select no block, one block, or reject duplicates.
#
# input:
# ```Kaifile
#    alpha beta { first }
#    beta alpha { reordered }
#    alpha { selected }
# ```
expect {
	blocks = Config.scan(
		"alpha beta { first }\nbeta alpha { reordered }\nalpha { selected }",
	)?
	Config.select_exact(blocks, ["missing"]) == Ok(Missing) and
		Config.select_exact(blocks, ["alpha"]) == Ok(Selected(blocks.get(2)?)) and
			Config.select_exact(blocks, ["alpha", "beta"]) == Ok(Selected(blocks.get(0)?))
}

# input:
# ```Kaifile
#   target { first }
#   target { second }
# ```
expect {
	blocks = Config.scan("target { first }\ntarget { second }")?
	Config.select_exact(blocks, ["target"]) == Err(
		DuplicateHeader({
			first: { byte_offset: 8, column: 9, line: 1 },
			header: ["target"],
			second: { byte_offset: 25, column: 9, line: 2 },
		}),
	)
}

# Host clauses remain generic top-level blocks for plugins to interpret later.
expect {
	source = "on linux {\n  shell {\n    pkgs: [\"cowsay\"]\n  }\n}\non macos {\n  shell {\n    pkgs: [\"fortune\"]\n  }\n}"
	match Config.scan(source) {
		Ok([linux, macos]) =>
			linux.header == ["on", "linux"] and
				linux.body == "\n  shell {\n    pkgs: [\"cowsay\"]\n  }\n" and
					linux.location == { byte_offset: 10, column: 11, line: 1 } and
						Config.scan(linux.body) == Ok([
							{
								body: "\n    pkgs: [\"cowsay\"]\n  ",
								header: ["shell"],
								location: { byte_offset: 10, column: 10, line: 2 },
							},
						]) and
							macos.header == ["on", "macos"] and
								macos.body == "\n  shell {\n    pkgs: [\"fortune\"]\n  }\n"
		_ => Bool.False
	}
}

# Preserve generic header words and an opaque nested body while ignoring
# structural characters in strings and comments.
expect {
	source = "# ☃\ndev-shell nix-unstable ☃ {\n  text: \"# } { \\\"\"\n  nested { value }\n  # }\n}\n"
	match Config.scan(source) {
		Ok([block]) =>
			block.header == ["dev-shell", "nix-unstable", "☃"] and
				block.location == { byte_offset: 34, column: 29, line: 2 } and
					block.body == "\n  text: \"# } { \\\"\"\n  nested { value }\n  # }\n"
		_ => Bool.False
	}
}

# Universal structural failures retain concise byte source locations.
expect {
	Config.scan("{") == Err({ kind: EmptyHeader, location: { byte_offset: 0, column: 1, line: 1 } }) and
		Config.scan("}") == Err({ kind: ExtraClosingBrace, location: { byte_offset: 0, column: 1, line: 1 } }) and
			Config.scan("shell") == Err({ kind: MalformedHeader, location: { byte_offset: 5, column: 6, line: 1 } }) and
				Config.scan("shell {") == Err({ kind: MissingClosingBrace, location: { byte_offset: 7, column: 8, line: 1 } }) and
					Config.scan("shell {\n \"oops }") == Err({ kind: UnterminatedString, location: { byte_offset: 9, column: 2, line: 2 } })
}
