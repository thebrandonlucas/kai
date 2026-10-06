## Kai's standard plugin: environments, shells, tasks, builds and workflows.
package
	[
		Std,
		Config,
		EnvName,
		FlakeRef,
		InputName,
		System,
		TaskName,
		Tool,
		Val,
		WorkflowName,
	]
	{
		pf: platform "../../platform/main.roc",
		model: "model/main.roc",
		nix: "backends/nix/main.roc",
		guix: "backends/guix/main.roc",
	}
