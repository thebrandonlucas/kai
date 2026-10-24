## Kai's standard plugin: environments, shells, tasks, builds and workflows.
package
	[
		Config,
		EnvName,
		FlakeRef,
		InputName,
		Std,
		System,
		TaskName,
		Tool,
		Val,
		WorkflowName,
	]
	{
		guix: "backends/guix/main.roc",
		model: "model/main.roc",
		nix: "backends/nix/main.roc",
		pf: platform "../../platform/main.roc",
	}

import Std
import pf.Conformance

# Std.roc's planning tests cover every implementation.
expect {
	cases = ["shell", "run", "build", "workflow", "update"]
		.join_map(|command| ["nix", "guix"].map(|backend| { command, backend }))
		.append({ command: "model", backend: "" })
	Conformance.missing(Std.plugin([Name("x")]), cases) == []
}
