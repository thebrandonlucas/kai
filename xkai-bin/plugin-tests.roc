app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	kai: "./package.roc",
}

import kai.Body
import kai.Plugin as PluginApi

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
}

main! = |_| Ok({})

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
