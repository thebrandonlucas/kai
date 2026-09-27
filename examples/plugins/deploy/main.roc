## An example plugin: `kai deploy HOST` switches a NixOS host to a flake
## output with nixos-rebuild, from an environment std declares.
package
	[Deploy]
	{
		pf: platform "../../../kaifile/platform/main.roc",
		std: "../../../plugins/std/main.roc",
	}
