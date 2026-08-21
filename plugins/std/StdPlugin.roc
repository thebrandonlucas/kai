import kai.Plugin
import backends.Nix as NixBackend
import commands.Build as BuildCommand
import commands.Shell as ShellCommand
import commands.Task as TaskCommand
import commands.Update as UpdateCommand
import commands.Workflow as WorkflowCommand
import implementations.BuildNix
import implementations.ShellNix
import implementations.TaskNix
import implementations.UpdateNix
import implementations.WorkflowNix
import selectors.StandardConfig

## `StdPlugin` is the standard plugin shipped for most `kai` users.
##
## It aims to wrap `nix` commands into easy-to-use pieces that match primary
## `nix` use cases. It also demonstrates the canonical use and structure of
# plugins and serve as an example of how to write them.
#
StdPlugin := [].{
	plugin : Plugin.RegistryDefinition
	plugin = {
		definition,
		select_config: StdPlugin.select_config,
	}

	## I almost feel like selection should be implied?
	## Like why can't i just have everything after line 86 (commands ...)
	# just be what is defined, and then upstream `kai` just knows how to
	# take the defined commands/backends/impl's and "select" them?
	# It just seems like select_config should be generic code that shouldn't
	# even exist here at all. Is it just because there's custom plugin specific
	# validation rules like described in docs/plans/plugin-mod/plan2.md? or are there 
	# other reasons this can't be lifted out of the plugin concern?

	select_config : Plugin.ConfigSelector
	select_config = |config_text, command, backend_choice, args, os, arch|
		if command.name == ShellCommand.command.name {
			StandardConfig.select_shell(
				{
					environment_body: ShellCommand.environment_body,
					environment_name_rules: ShellCommand.environment_name_rules,
				},
				config_text,
				command,
				backend_choice,
				args,
				os,
				arch,
			)
		} else if command.name == TaskCommand.command.name {
			StandardConfig.select_task(
				{
					body: TaskCommand.body,
					environment_body: ShellCommand.environment_body,
					environment_rules: TaskCommand.environment_rules,
					name_rules: TaskCommand.name_rules,
					run_rules: TaskCommand.run_rules,
				},
				config_text,
				backend_choice,
				args,
				os,
			)
		} else if command.name == BuildCommand.command.name {
			StandardConfig.select_build(
				{
					artifact_name_rules: BuildCommand.artifact_name_rules,
					body: BuildCommand.body,
					environment_body: ShellCommand.environment_body,
					environment_rules: BuildCommand.environment_rules,
					output_rules: BuildCommand.output_rules,
					run_rules: BuildCommand.run_rules,
				},
				config_text,
				backend_choice,
				args,
				os,
			)
		} else if command.name == WorkflowCommand.command.name {
			StandardConfig.select_workflow(
				{ body: WorkflowCommand.body, name_rules: WorkflowCommand.name_rules },
				config_text,
				backend_choice,
				args,
				os,
			)
		} else {
			Plugin.select_config(config_text, command, backend_choice, args, os, arch)
		}

	commands : List(Plugin.Command)
	commands = [
		BuildCommand.command,
		ShellCommand.command,
		TaskCommand.command,
		UpdateCommand.command,
		WorkflowCommand.command,
	]

	backends : List(Plugin.Backend)
	backends = [NixBackend.backend]

	implementations : List(Plugin.Implementation)
	implementations = [
		BuildNix.implementation,
		ShellNix.implementation,
		TaskNix.implementation,
		UpdateNix.implementation,
		WorkflowNix.implementation,
	]

	definition : Plugin.Definition
	definition = Plugin.Definition.{
		backends,
		commands,
		default_backend: NixBackend.backend.name,
		implementations,
		name: "std",
	}
}
