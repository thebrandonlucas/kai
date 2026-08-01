import pf.OsStr
import pf.Stdout

import kai.Plugin as PluginApi
import kai.Command
import kai.Backend
import kai.Implementation

StdPlugin := [].{

	run! = |_args| {
		Stdout.line!("running std plugin")
	}

	# FIXME: help me think through if this contract is correct
	# Basically i need a way to 
	# - write generic command interfaces but then say which ones they 
	#   apply to (guix may have `shell` but nix may not, or maybe i just
	#   haven't added the implementation yet, with this below arch i can 
	#   easily add it later).
	# - associate backends, commands, and implementations in a way that
	#   a command/backend combo is tied to an implementation (ex. the 
	#   command for shell should just define a simple contract with no inputs 
	#   and outputs (although I will admit that i don't yet know what to do 
	#   about side effects and for now am just having the handler handle them 
	#   all: maybe I can make a constrained list of allowed side effects for 
	#   certain commands?) )

	backends = [Backend.Nix, Backend.Guix]

	shell : Command
	shell = Command.{
		name: "shell",
		backends,
		argv: [],
	}

	nix_impl : Implementation
	nix_impl = Implementation.{
		command: shell,
		backend: nix,
		handler: {
			# TODO: this will be managed eventually in
			# either kai.roc or in .kai, but for now we
			# localize everything that isn't generic to
			# minimize refactoring later.
			refactor = {
				backend: {
					name: "nix",
					managed_filename: "flake.nix",
					shell_command: "develop",
					shell_command_args: ["path:.kai#default"],
				},
				config_filename: "kai.roc",
				managed_kai_dir: ".kai",
			}
			# We run the kai.roc file via the Roc compiler directly.
			# The platform validates and parses the config,
			# lowering it into the appropriate backend.
			#
			# Around here is where we will eventually include 
			# more effectful logic responsible for doing things 
			# like
			output = Cmd.new("roc")
				.args([
					refactor.config_filename,
				])
				.exec_output!()?
			# The string output is the resulting backend
			# dev shell config text. For Nix, this is
			# the contents of the flake.nix file.
			source = output.stdout_utf8
			# Kai creates and manages config in .kai under the hood.
			# Things like flake.nix/.lock, the selected backend, etc.
			# are written here.
			managed_kai_dir = Path.utf8(refactor.managed_kai_dir)
			if !Path.exists!(managed_kai_dir)? {
				Path.create_dir!(managed_kai_dir)?
			}
			managed_file = Path.join(
				managed_kai_dir,
				refactor.backend.managed_filename,
			)
			Path.write_utf8!(managed_file, source)?
			Stdout.line!(
				"wrote: ${refactor.backend.managed_filename}",
			)?
			Cmd.exec!(
				refactor.backend.name,
				[
					refactor.backend.shell_command,
				].concat(refactor.backend.shell_command_args),
			)
		},
	}

	plugin : PluginApi.Plugin(OsStr, [StdoutErr(_), ..])
	plugin = PluginApi.Plugin.{
		name: "std-plugin",
		commands: [
			shell,
		],
		backends: [],
		implementations: [],
		validator: |_| {},
		run!,
	}
}
