## Pure types and logic for the Kai CLI

## Right now this just supplies types and parsing for
## cli/main.roc
##
## This module is pure, side effects are kept separate from
## pure functions to make testing easier, following advice
## from the [Boundaries](https://www.destroyallsoftware.com/talks/boundaries)
## talk.
Cli := [].{
	Command := [Help, Shell, Version, Unknown(Str)].{
		is_eq : Command, Command -> Bool
		is_eq = |left, right|
			match (left, right) {
				(Help, Help) => Bool.True
				(Shell, Shell) => Bool.True
				(Version, Version) => Bool.True
				(Unknown(left_name), Unknown(right_name))
					=> left_name == right_name
				_ => Bool.False
			}
	}

	version : Str
	version = "0.0.1"

	usage : Str
	usage = "Kai - A friendly frontend for determinate computing"

	parse : List(Str) -> Command
	parse = |args|
		match args {
			[] => Help
			[first, ..] =>
				match first {
					"shell" => Shell
					"version" => Version
					unknown => Unknown(unknown)
				}
			}

	check : List(Str), Cli.Command -> Bool
	check = |args, expected| Cli.parse(args) == expected

	## -- TESTS --

	## No arguments displays help.
	expect check([], Cli.Command.Help)

	## Shell arg gives help text back
	expect check(["shell"], Cli.Command.Shell)

	## Additional shell arguments currently do not alter
	## command selection.
	## TODO: should we display help instead?
	expect check(["shell", "extra"], Cli.Command.Shell)

	## The version command selects version output.
	expect check(["version"], Cli.Command.Version)

	## Unknown commands retain their original spelling for diagnostics.
	expect check(["socrates"], Cli.Command.Unknown("socrates"))
}
