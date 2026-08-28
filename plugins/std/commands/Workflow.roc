import parser.Body
import kai.Kaifile
import kai.Plugin

Workflow := [].{
	name_rules : List(Plugin.TextRule)
	name_rules = [NonemptyText("workflow name must not be empty")]

	block : Plugin.KaifileBlock
	block = Kaifile.named_block({
		header: "workflow <workflow>",
		fields: [Body.required("steps", StringList)],
		name_rules,
	})

	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("workflow", [Plugin.required_argument("workflow")]),
		config: NamedConfig({ lookup: QualifiedThenUnqualified }),
		config_block: RequiredConfigBlock(block),
	}
}
