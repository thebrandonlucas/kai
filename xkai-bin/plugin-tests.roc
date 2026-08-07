app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	kai: "./package.roc",
}

import kai.Plugin as PluginApi

Fixtures := [].{
	context : PluginApi.RenderContext
	context = PluginApi.RenderContext.{
		args: [],
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
