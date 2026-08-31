# Package the GuixPlugin source code as data so xkai can compile it into a
# standalone kai binary.
import "GuixPlugin.roc" as guix_plugin_source : Str
import "backends/Guix.roc" as guix_backend_source : Str
import "schemas/Shell.roc" as shell_schema_source : Str
import "implementations/ShellGuix.roc" as shell_guix_source : Str

GuixBundle := [].{
	package_source = |modules, dependencies| {
		dependency_source = dependencies.map(
			|dependency| "${dependency.name}: \"${dependency.path}\"",
		)
		Str.join_with(
			[
				"package [${Str.join_with(modules, ", ")}] { ",
				Str.join_with(dependency_source, ", "),
				" }\n",
			],
			"",
		)
	}

	source_bundle = {
		app_dependencies: [],
		app_imports: [],
		files: [
			{
				destination: "guix/main.roc",
				contents: GuixBundle.package_source(
					["GuixPlugin"],
					[
						{ name: "backends", path: "./backends/main.roc" },
						{ name: "implementations", path: "./implementations/main.roc" },
						{ name: "kai", path: "../package.roc" },
						{ name: "schemas", path: "./schemas/main.roc" },
					],
				),
			},
			{ destination: "guix/GuixPlugin.roc", contents: guix_plugin_source },
			{
				destination: "guix/backends/main.roc",
				contents: GuixBundle.package_source(
					["Guix"],
					[{ name: "kai", path: "../../package.roc" }],
				),
			},
			{ destination: "guix/backends/Guix.roc", contents: guix_backend_source },
			{
				destination: "guix/schemas/main.roc",
				contents: GuixBundle.package_source(
					["Shell"],
					[
						{ name: "kai", path: "../../package.roc" },
						{ name: "parser", path: "../../parser/main.roc" },
					],
				),
			},
			{ destination: "guix/schemas/Shell.roc", contents: shell_schema_source },
			{
				destination: "guix/implementations/main.roc",
				contents: GuixBundle.package_source(
					["ShellGuix"],
					[
						{ name: "backends", path: "../backends/main.roc" },
						{ name: "kai", path: "../../package.roc" },
						{ name: "schemas", path: "../schemas/main.roc" },
					],
				),
			},
			{
				destination: "guix/implementations/ShellGuix.roc",
				contents: shell_guix_source,
			},
		],
	}

	custom_dependencies = {
		plugin: [{ name: "guix", path: "../guix/main.roc" }],
		backends: [{ name: "guix", path: "../../guix/main.roc" }],
		implementations: [{ name: "guix", path: "../../guix/main.roc" }],
		schemas: [{ name: "guix", path: "../../guix/main.roc" }],
	}

	registry_entry = {
		app_dependency: { name: "guix", path: "./guix/main.roc" },
		import_line: "import guix.GuixPlugin",
		expression: "GuixPlugin.plugin",
	}
}
