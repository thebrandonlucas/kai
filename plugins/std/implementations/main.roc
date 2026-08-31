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
		kai: "../../../xkai/package.roc",
		parser: "../../../xkai/parser/main.roc",
		schemas: "../schemas/main.roc",
	}
