# xkai pure command definitions
import "VERSION" as canonical_version : Str

Cli := [].{
	Command := [Help, Build, Version, Unknown(Str)].{
		is_eq : Command, Command -> Bool
		is_eq = |left, right|
			match (left, right) {
				(Help, Help) => Bool.True
				(Build, Build) => Bool.True
				(Version, Version) => Bool.True
				(Unknown(left_name), Unknown(right_name))
					=> left_name == right_name
				_ => Bool.False
			}
	}

	version : Str
	version = canonical_version

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
					"version" => Version
					unknown => Unknown(unknown)
				}
			}

	check : List(Str), Cli.Command -> Bool
	check = |args, expected| Cli.parse(args) == expected
}
