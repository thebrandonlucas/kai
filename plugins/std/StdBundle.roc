# Bundles the standard plugin sources for generated Kai runtimes.
import "StdPlugin.roc" as std_plugin_source : Str
import "backends/Nix.roc" as nix_backend_source : Str
import "configs/EnvironmentConfig.roc" as environment_config_source : Str
import "commands/Build.roc" as build_command_source : Str
import "commands/Image.roc" as image_command_source : Str
import "commands/Machine.roc" as machine_command_source : Str
import "commands/Secret.roc" as secret_command_source : Str
import "commands/Service.roc" as service_command_source : Str
import "commands/Shell.roc" as shell_command_source : Str
import "commands/Task.roc" as task_command_source : Str
import "commands/Update.roc" as update_command_source : Str
import "commands/Workflow.roc" as workflow_command_source : Str
import "implementations/BuildNix.roc" as build_nix_source : Str
import "implementations/EnvironmentNix.roc" as environment_nix_source : Str
import "implementations/ImageNix.roc" as image_nix_source : Str
import "implementations/MachineNix.roc" as machine_nix_source : Str
import "implementations/ServiceNix.roc" as service_nix_source : Str
import "implementations/ShellNix.roc" as shell_nix_source : Str
import "implementations/TaskNix.roc" as task_nix_source : Str
import "implementations/UpdateNix.roc" as update_nix_source : Str
import "implementations/WorkflowNix.roc" as workflow_nix_source : Str
import "project_configs/Source.roc" as source_config_source : Str

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
						{ name: "commands", path: "./commands/main.roc" },
						{ name: "implementations", path: "./implementations/main.roc" },
						{ name: "kai", path: "../package.roc" },
						{ name: "parser", path: "../parser/main.roc" },
						{ name: "project_configs", path: "./project_configs/main.roc" },
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
				destination: "std/configs/main.roc",
				contents: StdBundle.package_source(
					["EnvironmentConfig"],
					[
						{ name: "kai", path: "../../package.roc" },
						{ name: "parser", path: "../../parser/main.roc" },
					],
				),
			},
			{
				destination: "std/configs/EnvironmentConfig.roc",
				contents: environment_config_source,
			},
			{
				destination: "std/commands/main.roc",
				contents: StdBundle.package_source(
					[
						"Build",
						"Image",
						"Machine",
						"Secret",
						"Service",
						"Shell",
						"Task",
						"Update",
						"Workflow",
					],
					[
						{ name: "configs", path: "../configs/main.roc" },
						{ name: "kai", path: "../../package.roc" },
						{ name: "parser", path: "../../parser/main.roc" },
					],
				),
			},
			{ destination: "std/commands/Build.roc", contents: build_command_source },
			{ destination: "std/commands/Image.roc", contents: image_command_source },
			{
				destination: "std/commands/Machine.roc",
				contents: machine_command_source,
			},
			{ destination: "std/commands/Secret.roc", contents: secret_command_source },
			{
				destination: "std/commands/Service.roc",
				contents: service_command_source,
			},
			{ destination: "std/commands/Shell.roc", contents: shell_command_source },
			{ destination: "std/commands/Task.roc", contents: task_command_source },
			{ destination: "std/commands/Update.roc", contents: update_command_source },
			{
				destination: "std/commands/Workflow.roc",
				contents: workflow_command_source,
			},
			{
				destination: "std/project_configs/main.roc",
				contents: StdBundle.package_source(
					["Source"],
					[
						{ name: "kai", path: "../../package.roc" },
						{ name: "parser", path: "../../parser/main.roc" },
					],
				),
			},
			{
				destination: "std/project_configs/Source.roc",
				contents: source_config_source,
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
						{ name: "commands", path: "../commands/main.roc" },
						{ name: "configs", path: "../configs/main.roc" },
						{ name: "kai", path: "../../package.roc" },
						{ name: "parser", path: "../../parser/main.roc" },
						{ name: "project_configs", path: "../project_configs/main.roc" },
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
		commands: [{ name: "std", path: "../../std/main.roc" }],
		backends: [{ name: "std", path: "../../std/main.roc" }],
		implementations: [{ name: "std", path: "../../std/main.roc" }],
	}

	registry_entry = {
		app_dependency: { name: "std", path: "./std/main.roc" },
		import_line: "import std.StdPlugin",
		expression: "StdPlugin.plugin",
	}
}
