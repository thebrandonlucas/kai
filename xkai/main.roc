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
			# read a file called kai.module.roc
			# import it as a plugin then do this: 
			# commands = [
			#       plugin
			# ]

			# run!(plugin)

			# for now assume literally all other work is done in there 
			#   including side effects

		}
		Cli.Command.Unknown(unknown) => {
			Stdout.line!("Unknown command ${unknown}")?
			print_usage!({})
		}
	}
}
