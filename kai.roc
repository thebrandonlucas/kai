app [config, module_changes] {
	kai: platform "./platform/main.roc",
}

import kai.Kai
import kai.Command

config = {
	name: "Kai developer shell",
	shell: {
		pkgs: [
			# TODO: Unfortunately we are blocked on true parity with
			#       this project's flake.nix because we can't use
			#       overlays yet (needed for roc nightly compiler)
			#
			#       When we can we'll be able to self-host kai completely!
			"roc",
			"shfmt",
			"zig_0_16",
			"diffutils",
			"shfmt",
		],
	},
}

custom_shell_handler : Command.Handler
custom_shell_handler = |request| {
	default_implementation = Kai.default_nix_shell(Kai.config(config))
	default_handler = default_implementation.handler
	plan = default_handler(request)?

	## FIXME: impure?
	Ok({ files: plan.files, argv: plan.argv.append("--impure") })
}

custom_shell : Command.Implementation
custom_shell = {
	command: "shell",
	contract: "kai.shell.v1",
	id: "example.shell.custom.nix",
	backends: [Command.Backend.Nix],
	handler: custom_shell_handler,
}

module_changes : List(Kai.CommandChange)
module_changes = [
	Kai.CommandChange.Replace(custom_shell),
]

expect {
	registry = Kai.registry(Kai.config(config), module_changes)?
	selected = Command.select(registry, "shell", Command.Backend.Nix)?

	selected.id == "example.shell.custom.nix"
}
