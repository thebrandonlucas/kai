app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
}

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
		# Cli.Command.Shell => {
		# 	# We run the kai.roc file via the Roc compiler directly.
		# 	# The platform validates and parses the config,
		# 	# lowering it into the appropriate backend.
		# 	#
		# 	# Around here is where we will eventually include
		# 	# more effectful logic responsible for doing things
		# 	# like
		# 	output = Cmd.new("roc")
		# 		.args([
		# 			refactor.config_filename,
		# 		])
		# 		.exec_output!()?
		# 	# The string output is the resulting backend
		# 	# dev shell config text. For Nix, this is
		# 	# the contents of the flake.nix file.
		# 	source = output.stdout_utf8
		# 	# Kai creates and manages config in .kai under the hood.
		# 	# Things like flake.nix/.lock, the selected backend, etc.
		# 	# are written here.
		# 	managed_kai_dir = Path.utf8(refactor.managed_kai_dir)
		# 	if !Path.exists!(managed_kai_dir)? {
		# 		Path.create_dir!(managed_kai_dir)?
		# 	}
		# 	managed_file = Path.join(
		# 		managed_kai_dir,
		# 		refactor.backend.managed_filename,
		# 	)
		# 	Path.write_utf8!(managed_file, source)?
		# 	Stdout.line!(
		# 		"wrote: ${refactor.backend.managed_filename}",
		# 	)?
		# 	Cmd.exec!(
		# 		refactor.backend.name,
		# 		[
		# 			refactor.backend.shell_command,
		# 		].concat(refactor.backend.shell_command_args),
		# 	)
		#
		# }
		#
		# Cli.Command.Version => Stdout.line!("kai version ${Cli.version}")
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
			plugin_source = Path.read_utf8!(Path.utf8("plugins/kai.module.roc"))?
			Path.write_utf8!(
				# TODO: allow multiple plugins
				Path.join(generated_dir, "Plugin.roc"),
				plugin_source,
			)?

			cli_source = Str.join_with(
				[
					"app [main!] {",
					"\tpf: platform \"https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst\",",
					"}",
					"",
					"import Plugin",
					"",
					"main! = |plugin_args| Plugin.run!(plugin_args)",
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
