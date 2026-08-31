# Shared `command` interface for defining/running `workflow`s.
#
# These are very useful for running a series of `task`s in certain
# `environments`.
import kai.Kaifile
import kai.Plugin

Workflow := [].{
	name_rules : List(Plugin.TextRule)
	name_rules = [NonemptyText("workflow name must not be empty")]

	block : Plugin.Block
	block = Kaifile.named_block({
		header: "workflow <workflow>",
		fields: [Kaifile.required("steps", StringList)],
		name_rules,
	})

	command_syntax : Plugin.CommandSyntax
	command_syntax = Plugin.command_syntax(
		"workflow",
		[Plugin.required_argument("workflow")],
	)

	command : Plugin.Command
	command = Plugin.command_with_block({ syntax: command_syntax, block })
}
