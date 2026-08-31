# Bundles the standard plugin sources for generated Kai runtimes.
import "StdPlugin.roc" as std_plugin_source : Str
import "backends/Nix.roc" as nix_backend_source : Str
import "schemas/Build.roc" as build_schema_source : Str
import "schemas/EnvironmentConfig.roc" as environment_schema_source : Str
import "schemas/Image.roc" as image_schema_source : Str
import "schemas/Machine.roc" as machine_schema_source : Str
import "schemas/MachineConfig.roc" as machine_config_schema_source : Str
import "schemas/Secret.roc" as secret_schema_source : Str
import "schemas/Service.roc" as service_schema_source : Str
import "schemas/Shell.roc" as shell_schema_source : Str
import "schemas/Source.roc" as source_schema_source : Str
import "schemas/Task.roc" as task_schema_source : Str
import "schemas/Update.roc" as update_schema_source : Str
import "schemas/Workflow.roc" as workflow_schema_source : Str
import "implementations/BuildNix.roc" as build_nix_source : Str
import "implementations/EnvironmentNix.roc" as environment_nix_source : Str
import "implementations/ImageNix.roc" as image_nix_source : Str
import "implementations/MachineNix.roc" as machine_nix_source : Str
import "implementations/ServiceNix.roc" as service_nix_source : Str
import "implementations/ShellNix.roc" as shell_nix_source : Str
import "implementations/TaskNix.roc" as task_nix_source : Str
import "implementations/UpdateNix.roc" as update_nix_source : Str
import "implementations/WorkflowNix.roc" as workflow_nix_source : Str

StdBundle := [].{
	package_source = |modules, dependencies| {
		dependency_sources = dependencies.map(
			|dependency| "${dependency.name}: \"${dependency.path}\"",
		)
		module_list = Str.join_with(modules, ", ")
		dependency_list = Str.join_with(dependency_sources, ", ")
		"package [${module_list}] { ${dependency_list} }\n"
	}

	source_bundle = {
		app_dependencies: [],
		app_imports: [],
		files: [
			{
				destination: "std/main.roc",
				contents: StdBundle.package_source(
					["StdPlugin"],
					[
						{ name: "backends", path: "./backends/main.roc" },
						{ name: "implementations", path: "./implementations/main.roc" },
						{ name: "kai", path: "../package.roc" },
						{ name: "parser", path: "../parser/main.roc" },
						{ name: "schemas", path: "./schemas/main.roc" },
					],
				),
			},
			{ destination: "std/StdPlugin.roc", contents: std_plugin_source },
			{
				destination: "std/backends/main.roc",
				contents: StdBundle.package_source(
					["Nix"],
					[
						{ name: "kai", path: "../../package.roc" },
						{ name: "parser", path: "../../parser/main.roc" },
					],
				),
			},
			{ destination: "std/backends/Nix.roc", contents: nix_backend_source },
			{
				destination: "std/schemas/main.roc",
				contents: StdBundle.package_source(
					[
						"Build",
						"EnvironmentConfig",
						"Image",
						"Machine",
						"MachineConfig",
						"Secret",
						"Service",
						"Shell",
						"Source",
						"Task",
						"Update",
						"Workflow",
					],
					[
						{ name: "kai", path: "../../package.roc" },
						{ name: "parser", path: "../../parser/main.roc" },
					],
				),
			},
			{ destination: "std/schemas/Build.roc", contents: build_schema_source },
			{
				destination: "std/schemas/EnvironmentConfig.roc",
				contents: environment_schema_source,
			},
			{ destination: "std/schemas/Image.roc", contents: image_schema_source },
			{
				destination: "std/schemas/Machine.roc",
				contents: machine_schema_source,
			},
			{
				destination: "std/schemas/MachineConfig.roc",
				contents: machine_config_schema_source,
			},
			{ destination: "std/schemas/Secret.roc", contents: secret_schema_source },
			{
				destination: "std/schemas/Service.roc",
				contents: service_schema_source,
			},
			{ destination: "std/schemas/Shell.roc", contents: shell_schema_source },
			{ destination: "std/schemas/Source.roc", contents: source_schema_source },
			{ destination: "std/schemas/Task.roc", contents: task_schema_source },
			{ destination: "std/schemas/Update.roc", contents: update_schema_source },
			{
				destination: "std/schemas/Workflow.roc",
				contents: workflow_schema_source,
			},
			{
				destination: "std/implementations/main.roc",
				contents: StdBundle.package_source(
					[
						"BuildNix",
						"EnvironmentNix",
						"ImageNix",
						"MachineNix",
						"ServiceNix",
						"ShellNix",
						"TaskNix",
						"UpdateNix",
						"WorkflowNix",
					],
					[
						{ name: "backends", path: "../backends/main.roc" },
						{ name: "kai", path: "../../package.roc" },
						{ name: "parser", path: "../../parser/main.roc" },
						{ name: "schemas", path: "../schemas/main.roc" },
					],
				),
			},
			{
				destination: "std/implementations/BuildNix.roc",
				contents: build_nix_source,
			},
			{
				destination: "std/implementations/EnvironmentNix.roc",
				contents: environment_nix_source,
			},
			{
				destination: "std/implementations/ImageNix.roc",
				contents: image_nix_source,
			},
			{
				destination: "std/implementations/MachineNix.roc",
				contents: machine_nix_source,
			},
			{
				destination: "std/implementations/ServiceNix.roc",
				contents: service_nix_source,
			},
			{
				destination: "std/implementations/ShellNix.roc",
				contents: shell_nix_source,
			},
			{
				destination: "std/implementations/TaskNix.roc",
				contents: task_nix_source,
			},
			{
				destination: "std/implementations/UpdateNix.roc",
				contents: update_nix_source,
			},
			{
				destination: "std/implementations/WorkflowNix.roc",
				contents: workflow_nix_source,
			},
		],
	}

	custom_dependencies = {
		plugin: [{ name: "std", path: "../std/main.roc" }],
		backends: [{ name: "std", path: "../../std/main.roc" }],
		implementations: [{ name: "std", path: "../../std/main.roc" }],
		schemas: [{ name: "std", path: "../../std/main.roc" }],
	}

	registry_entry = {
		app_dependency: { name: "std", path: "./std/main.roc" },
		import_line: "import std.StdPlugin",
		expression: "StdPlugin.plugin",
	}
}
