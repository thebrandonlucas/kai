## The machine plugin: machines a Kaifile declares, `kai machine`, which
## builds one and switches a host to it, and `kai secret`, which encrypts
## its secrets. Machine.roc reads and checks the settings into
## MachineModel.roc's machines; NixosBackend.roc implements the commands on
## the nix backend, rendering each machine as NixOS. Each typed service is a
## module of the services package, such as services/Caddy.roc.
package
	[Machine]
	{
		pf: platform "../../platform/main.roc",
		services: "services/main.roc",
		std: "../std/main.roc",
	}

import Machine
import pf.Conformance

# Machine.roc's planning tests cover both implementations.
expect {
	cases = [
		{ command: "machine", backend: "nix" },
		{ command: "secret", backend: "nix" },
	]
	Conformance.missing(Machine.plugin([Name("x")], []), cases) == []
}
