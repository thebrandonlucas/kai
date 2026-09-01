# Lists the standard plugin sources embedded in generated Kai runtimes.
import "StdPlugin.roc" as std_plugin_source : Str
import "backends/Nix.roc" as nix_backend_source : Str
import "schemas/blocks/Build.roc" as build_block_source : Str
import "schemas/blocks/Environment.roc" as environment_block_source : Str
import "schemas/blocks/Machine.roc" as machine_block_source : Str
import "schemas/blocks/Secret.roc" as secret_block_source : Str
import "schemas/blocks/Service.roc" as service_block_source : Str
import "schemas/blocks/Shell.roc" as shell_block_source : Str
import "schemas/blocks/Source.roc" as source_block_source : Str
import "schemas/blocks/Task.roc" as task_block_source : Str
import "schemas/blocks/Workflow.roc" as workflow_block_source : Str
import "schemas/commands/Build.roc" as build_command_source : Str
import "schemas/commands/Image.roc" as image_command_source : Str
import "schemas/commands/Machine.roc" as machine_command_source : Str
import "schemas/commands/Run.roc" as run_command_source : Str
import "schemas/commands/Service.roc" as service_command_source : Str
import "schemas/commands/Shell.roc" as shell_command_source : Str
import "schemas/commands/Update.roc" as update_command_source : Str
import "schemas/commands/Workflow.roc" as workflow_command_source : Str
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
		blocks: [
			{ filename: "Build.roc", contents: build_block_source },
			{ filename: "Environment.roc", contents: environment_block_source },
			{ filename: "Machine.roc", contents: machine_block_source },
			{ filename: "Secret.roc", contents: secret_block_source },
			{ filename: "Service.roc", contents: service_block_source },
			{ filename: "Shell.roc", contents: shell_block_source },
			{ filename: "Source.roc", contents: source_block_source },
			{ filename: "Task.roc", contents: task_block_source },
			{ filename: "Workflow.roc", contents: workflow_block_source },
		],
		commands: [
			{ filename: "Build.roc", contents: build_command_source },
			{ filename: "Image.roc", contents: image_command_source },
			{ filename: "Machine.roc", contents: machine_command_source },
			{ filename: "Run.roc", contents: run_command_source },
			{ filename: "Service.roc", contents: service_command_source },
			{ filename: "Shell.roc", contents: shell_command_source },
			{ filename: "Update.roc", contents: update_command_source },
			{ filename: "Workflow.roc", contents: workflow_command_source },
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
