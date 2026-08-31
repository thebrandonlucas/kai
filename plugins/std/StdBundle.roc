# Lists the standard plugin sources embedded in generated Kai runtimes.
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
	plugin_source = {
		package_name: "std",
		module_name: "StdPlugin",
		module_source: {
			filename: "StdPlugin.roc",
			contents: std_plugin_source,
		},
		schemas: [
			{ filename: "Build.roc", contents: build_schema_source },
			{
				filename: "EnvironmentConfig.roc",
				contents: environment_schema_source,
			},
			{ filename: "Image.roc", contents: image_schema_source },
			{ filename: "Machine.roc", contents: machine_schema_source },
			{
				filename: "MachineConfig.roc",
				contents: machine_config_schema_source,
			},
			{ filename: "Secret.roc", contents: secret_schema_source },
			{ filename: "Service.roc", contents: service_schema_source },
			{ filename: "Shell.roc", contents: shell_schema_source },
			{ filename: "Source.roc", contents: source_schema_source },
			{ filename: "Task.roc", contents: task_schema_source },
			{ filename: "Update.roc", contents: update_schema_source },
			{ filename: "Workflow.roc", contents: workflow_schema_source },
		],
		backends: [{ filename: "Nix.roc", contents: nix_backend_source }],
		implementations: [
			{ filename: "BuildNix.roc", contents: build_nix_source },
			{ filename: "EnvironmentNix.roc", contents: environment_nix_source },
			{ filename: "ImageNix.roc", contents: image_nix_source },
			{ filename: "MachineNix.roc", contents: machine_nix_source },
			{ filename: "ServiceNix.roc", contents: service_nix_source },
			{ filename: "ShellNix.roc", contents: shell_nix_source },
			{ filename: "TaskNix.roc", contents: task_nix_source },
			{ filename: "UpdateNix.roc", contents: update_nix_source },
			{ filename: "WorkflowNix.roc", contents: workflow_nix_source },
		],
	}
}
