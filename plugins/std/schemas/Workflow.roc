# Shared `command` interface for defining/running `workflow`s.
#
# These are very useful for running a series of `task`s in certain
# `environments`.
import kai.Kaifile
import kai.Plugin

Workflow := [].{
	name_rules : List(Plugin.TextRule)
	name_rules = [NonemptyText("workflow name must not be empty")]

	block : Plugin.KaifileBlock
	block = Kaifile.named_block({
		header: "workflow <workflow>",
		fields: [Kaifile.required("steps", StringList)],
		name_rules,
	})

	command : Plugin.Command
	command = Plugin.command("workflow", [Plugin.required_argument("workflow")])

	command_schema : Plugin.CommandSchema
	command_schema = Plugin.command_with_block({ command, block })
}
