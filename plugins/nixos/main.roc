## The nixos plugin: NixOS machines a Kaifile declares, rendered into std's
## generated flake as nixosConfigurations and built with `kai machine`.
## Nixos.roc reads and checks the settings and plans the command;
## NixosBackend.roc renders each machine as Nix.
package
	[Nixos]
	{
		pf: platform "../../platform/main.roc",
		std: "../std/main.roc",
	}

import Nixos
import pf.Conformance

# Nixos.roc's planning tests cover its one implementation.
expect {
	cases = [{ command: "machine", backend: "nix" }]
	Conformance.missing(Nixos.plugin([Name("x")], []), cases) == []
}
