## An example plugin: `kai deploy HOST` switches a NixOS host to a flake
## output with nixos-rebuild, from an environment std declares.
package
	[Deploy]
	{
		pf: platform "../../../platform/main.roc",
		std: "../../../plugins/std/main.roc",
	}

import Deploy
import pf.Conformance

# Deploy.roc's planning test covers its one implementation.
expect {
	cases = [{ command: "deploy", backend: "nix" }]
	Conformance.missing(Deploy.plugin([], []), cases) == []
}
