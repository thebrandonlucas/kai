# This is the equivalent of the StdPlugin,
# but written in Nix
import kai.Plugin as P

GuixShellPlugin := [].{
	ShellConfig : { pkgs : List(Str) }

	guix : P.Backend
	guix = P.Backend.{
		name: "guix",
	}

	shell_command : P.Command
	shell_command = P.Command.{
		argv: [],
		backends: [guix],
		name: "shell",
	}

	implementation : P.Implementation
	implementation = P.Implementation.{
		actions: [
			WriteConfigUtf8({ path: ".kai/manifest.scm" }),
			Exec({
				args: ["shell", "--manifest=.kai/manifest.scm"],
				command: guix.name,
			}),
		],
		backend: guix,
		command: shell_command,
		requirement: Program(guix.name),
	}

	shell : ShellConfig -> {
		implementation : P.Implementation,
		rendered_config : Str,
	}
	shell = |config| {
		implementation,
		rendered_config: GuixShellPlugin.render_manifest(config.pkgs),
	}

	render_manifest : List(Str) -> Str
	render_manifest = |pkgs| {
		specifications = pkgs.map(|pkg| "\"${pkg}\"")
		"(specifications->manifest (list ${Str.join_with(specifications, " ")}))\n"
	}
}

expect {
	module_config = GuixShellPlugin.shell({ pkgs: ["hello"] })
	module_config.implementation == GuixShellPlugin.implementation and
		module_config.rendered_config == "(specifications->manifest (list \"hello\"))\n"
}
