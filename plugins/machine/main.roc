## The machine plugin: machines a Kaifile declares and `kai machine`, which
## builds one and switches a host to it. Machine.roc reads and checks the
## settings into MachineModel.roc's machines; NixosBackend.roc implements
## the command on the nix backend, rendering each machine as NixOS.
package
	[Machine]
	{
		pf: platform "../../platform/main.roc",
		std: "../std/main.roc",
	}

import Machine
import pf.Conformance

# Machine.roc's planning tests cover its one implementation.
expect {
	cases = [{ command: "machine", backend: "nix" }]
	Conformance.missing(Machine.plugin([Name("x")], []), cases) == []
}
