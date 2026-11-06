## The guix plugin: std's shells, tasks, builds and workflows on Guix, from
## the project's std settings. Guix.roc plans each command; GuixBackend.roc
## renders the guix argv, channel and build files, and the lock section.
package
	[Guix]
	{
		pf: platform "../../platform/main.roc",
		std: "../std/main.roc",
	}

import Guix
import pf.Conformance

# Guix.roc's planning tests cover every implementation.
expect {
	cases = ["shell", "run", "build", "workflow", "update"]
		.map(|command| { command, backend: "guix" })
	Conformance.missing(Guix.plugin([Name("x")], []), cases) == []
}
