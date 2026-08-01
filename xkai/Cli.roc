# xkai pure command definitions
Cli := [].{
	Command := [Help, Build, Unknown(Str)].{
		is_eq : Command, Command -> Bool
		is_eq = |left, right|
			match (left, right) {
				(Help, Help) => Bool.True
				(Build, Build) => Bool.True
				(Unknown(left_name), Unknown(right_name))
					=> left_name == right_name
				_ => Bool.False
			}
	}

	usage : Str
	usage = "xkai - build plugins for kai"

	parse : List(Str) -> Command
	parse = |args|
		match args {
			[] => Help
			[first, ..] =>
				match first {
					"build" => Build
					"help" => Help
					unknown => Unknown(unknown)
				}
			}

	check : List(Str), Cli.Command -> Bool
	check = |args, expected| Cli.parse(args) == expected

	## -- TESTS --

	## No arguments displays help.
	expect check([], Cli.Command.Help)

	## No arguments displays help.
	expect check([], Cli.Command.Build)

	## Unknown commands retain their original spelling for diagnostics.
	expect check(["socrates"], Cli.Command.Unknown("socrates"))
}
