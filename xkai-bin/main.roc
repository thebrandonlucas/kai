app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
}

# I don't think platform code needs to supply side-effectful code?
# since all it's doing is defining the interface Command/Backend/Impl
# which we verify as valid (or at least, there's no internal logic issue)
# then our cli runs it? and if our CLI runs and finds that those commands
# or the backend doesn't exist, it throws a runtime error (might be worth
# investigating whether this is a necessary error?)

# xkai must be responsible for this validation
# and then the cli must be responsible for the
# peripheral error handling

import pf.OsStr
import pf.Stdout
import pf.Path
import pf.Cmd

import Cli

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

			# TODO: make plugin source a flag that you can
			# pass in, with a sensible default
			plugin_source = Path.read_utf8!(Path.utf8("plugins/StdPlugin.roc"))?
			Path.write_utf8!(
				# TODO: allow multiple plugins
				Path.join(generated_dir, "StdPlugin.roc"),
				plugin_source,
			)?
			executor_source = Path.read_utf8!(Path.utf8("xkai-bin/Executor.roc"))?
			Path.write_utf8!(
				Path.join(generated_dir, "Executor.roc"),
				executor_source,
			)?

			# TODO: this only builds the std_plugin kai, need to variablize it
			cli_source = Str.join_with(
				[
					"app [main!] {",
					"\tpf: platform \"https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst\",",
					"\tkai: \"../xkai-bin/package.roc\"",
					"}",
					"",
					"import Executor",
					"import StdPlugin",
					"",
					"main! = |args| Executor.run!(StdPlugin.plugin, args)",
				],
				"\n",
			)

			# TODO: generated file should be called something like
			# module or plugin
			Path.write_utf8!(Path.join(generated_dir, "cli.roc"), cli_source)?
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
