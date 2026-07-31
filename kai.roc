app [config] {
	kai: platform "./platform/main.roc",
}

import kai.Kai
import kai.Command

project_config : List(Kai.CommandChange) -> Kai.Config
project_config = |commands| {
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
	commands,
}

custom_shell_handler : Command.Handler
custom_shell_handler = |request| {
	default_implementation = Kai.default_nix_shell(project_config([]))
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

config : Kai.Config
config = project_config([
	Kai.CommandChange.Replace(custom_shell),
])

## TODO: We should try to figure out how to make the base
## case as dead-simple as it was before. This is only for advanced
# users who want to add modules and even then might need to be simplified.
# Certainly I wouldn't expect them to be writing logic tests in here.
expect {
	registry = Kai.registry(config)?
	selected = Command.select(registry, "shell", Command.Backend.Nix)?

	selected.id == "example.shell.custom.nix"
}
