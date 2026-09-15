# Command schema for building a declared machine service.
import kai.Plugin
import blocks.Service as ServiceBlock

Service := [].{
	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax_with_help(
		"service",
		[Plugin.required_argument("service")],
		{
			arguments: [
				{
					description: "Service name from the Kaifile",
					name: "SERVICE",
					presence: RequiredHelpArgument,
				},
			],
			description: "Build a service declared in the Kaifile.",
			examples: ["kai service <my-service>"],
			kaifile_block_example: KaifileBlockExample([
				\\secret <my-secret> {
				\\	provider: sops
				\\	file: "secrets/my-secret.json"
				\\}
				\\
				\\service <my-service> {
				\\	artifact: "my-artifact"
				\\	secrets: ["my-secret"]
				\\	restart: on-failure
				\\}
				,
			]),
		},
	)

	command : Plugin.Command
	command = Plugin.command_with_block({
		syntax: command_syntax,
		block: ServiceBlock.block,
	})
}
