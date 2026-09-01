# Kaifile block schema for workflows.
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

}
