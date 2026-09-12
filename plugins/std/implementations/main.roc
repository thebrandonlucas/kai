package
	[
		BuildNix,
		EnvironmentNix,
		GenerationsNix,
		ImageNix,
		MachineNix,
		RollbackNix,
		ServiceNix,
		ShellNix,
		SwitchNix,
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
