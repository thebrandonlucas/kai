# Planning test for the split plugin's local implementation.
import backends.Local
import blocks.Split as SplitBlock
import commands.SplitCommand
import implementations.SplitLocal
import kai.Plugin
import util.PlanCheck

SplitLocalTest := [].{}

definition = Plugin.Definition.{
	backends: [Local.backend],
	implementations: [SplitLocal.implementation],
	name: "split",
	schema: {
		blocks: [SplitBlock.block],
		commands: [SplitCommand.command],
	},
}

# The local split command writes its demonstration output.
expect {
	PlanCheck.plan(
		{
			definitions: [definition],
			host: { arch: X64, os: LINUX },
			kaifile: "split {}",
			workspace_root: ".kai",
		},
		["split-command"],
		Succeeds([
			ContainsStep(
				WriteFile({
					contents: "split plugin worked",
					path: "split-plugin-output.txt",
				}),
			),
		]),
	)
}
