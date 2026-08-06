app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
}

import pf.OsStr
import pf.Stdout
import pf.Path
import pf.Cmd

import Cli

import "Executor.roc" as executor_source : Str
import "generated-portable-cli.txt" as generated_cli_source : Str
import "package.roc" as package_source : Str
import "Plugin.roc" as plugin_source : Str
import "../plugins/StdPlugin.roc" as std_plugin_source : Str
import "VERSION" as version_source : Str

print_usage! : {} => Try({}, _)
print_usage! = |_| {
	Stdout.line!(Cli.usage)?
	Ok({})
}

main! : List(OsStr) => Try({}, _)
main! = |args| {
	display_args = args.drop_first(1).map(OsStr.display)
	match Cli.parse(display_args) {
		Cli.Command.Help => print_usage!({})
		Cli.Command.Version => {
			Stdout.line!("xkai version ${Cli.version}")?
			Ok({})
		}
		Cli.Command.Build => {
			# TODO: Look into how Caddy does per-repo vs. full
			# config. Should probably have a top-level one for
			# the cli like at ~/.config/kai to config things like
			# dirs
			generated_dir = Path.utf8(".kai")
			if !Path.exists!(generated_dir)? {
				Path.create_dir!(generated_dir)?
			}

			# TODO: errors must be much more informative

			# Materialize sources embedded when xkai was compiled. The generated CLI
			# can then be built without xkai-bin/ being present at runtime.
			Path.write_utf8!(Path.join(generated_dir, "Executor.roc"), executor_source)?
			Path.write_utf8!(Path.join(generated_dir, "package.roc"), package_source)?
			Path.write_utf8!(Path.join(generated_dir, "Plugin.roc"), plugin_source)?
			Path.write_utf8!(Path.join(generated_dir, "VERSION"), version_source)?

			std_dir = Path.join(generated_dir, "std")
			Path.create_all!(std_dir)?
			Path.write_utf8!(
				Path.join(std_dir, "main.roc"),
				"package [StdPlugin] { kai: \"../package.roc\" }\n",
			)?
			Path.write_utf8!(Path.join(std_dir, "StdPlugin.roc"), std_plugin_source)?

			Path.write_utf8!(Path.join(generated_dir, "cli.roc"), generated_cli_source)?
			# TODO: generalize output
			Cmd.exec!("roc", ["build", ".kai/cli.roc", "--output=kai"])

			# TODO: verify/validate plugin correctness
			# Should:
			# - A) conform to the Command/Backend/Implementation structure
			# - B) constrain it to the set of deterministic protocol commands

			# Also, a user really shouldn't have to write this much custom code
			# but rather high-level define their plugin structure, just the inputs/
			# outputs, the backend commands to run (e.g. nix build -> ...)
		}
		Cli.Command.Unknown(unknown) => {
			Stdout.line!("Unknown command ${unknown}")?
			print_usage!({})
		}
	}
}

## -- TESTS --

## No arguments displays help.
expect Cli.check([], Cli.Command.Help)

## Build is recognized.
expect Cli.check(["build"], Cli.Command.Build)

## Help is recognized.
expect Cli.check(["help"], Cli.Command.Help)

## Version is recognized.
expect Cli.check(["version"], Cli.Command.Version)

## Unknown commands retain their original spelling for diagnostics.
expect Cli.check(["socrates"], Cli.Command.Unknown("socrates"))
