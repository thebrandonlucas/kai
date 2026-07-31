## Top-level CLI interface and entry point for Kai.
##
## It takes in args from the CLI, validates them, then
## runs the associated commands.
##
## All app I/O and side-effects performed here
## to separate boundaries and keep other code pure and testable.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}

import pf.OsStr
import pf.Stdout
import pf.Path
import pf.Cmd

import Cli

# TODO: this will be managed eventually in
# either kai.roc or in .kai, but for now we
# localize everything that isn't generic to
# minimize refactoring later.
refactor = {
	backend: {
		name: "nix",
		managed_filename: "flake.nix",
		shell_command: "develop",
		shell_command_args: ["path:.kai/generated#default"],
	},
	config_filename: "kai.roc",
	managed_kai_dir: ".kai/generated",
}

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
		Cli.Command.Shell => {
			evaluator_path = ".kai/cache/kai-config"
			_ = Cmd.new("scripts/check-kai-composition.sh")
				.args([
					".",
					"kai.shell.default.nix",
					evaluator_path,
				])
				.exec_output!()?

			# Canonical kai.roc is a pure module. The checker stages it
			# under its module-compatible name and builds the evaluator.
			output = Cmd.new(evaluator_path)
				.exec_output!()?
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

		}

		Cli.Command.Version => Stdout.line!("kai version ${Cli.version}")
		Cli.Command.Unknown(unknown) => {
			Stdout.line!("Unknown command ${unknown}")?
			print_usage!({})
		}
	}
}
