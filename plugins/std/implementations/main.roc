package
	[
		BuildNix,
		EnvironmentNix,
		ImageNix,
		MachineNix,
		ServiceNix,
		ShellNix,
		TaskNix,
		UpdateNix,
		WorkflowNix,
	]
	{
		backends: "../backends/main.roc",
		blocks: "../schemas/blocks/main.roc",
		commands: "../schemas/commands/main.roc",
		kai: "../../../xkai/package.roc",
		parser: "../../../xkai/parser/main.roc",
	}
