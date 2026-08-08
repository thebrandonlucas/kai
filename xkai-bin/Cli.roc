# xkai pure command definitions
import "VERSION" as canonical_version : Str

Cli := [].{
	Command := [Help, Build(List(Str)), Version, Unknown(Str)].{
		is_eq : Command, Command -> Bool
		is_eq = |left, right|
			match (left, right) {
				(Help, Help) => Bool.True
				(Build(left_plugins), Build(right_plugins)) => left_plugins == right_plugins
				(Version, Version) => Bool.True
				(Unknown(left_name), Unknown(right_name))
					=> left_name == right_name
				_ => Bool.False
			}
	}

	version : Str
	version = canonical_version

	usage : Str
	usage = "Usage: xkai build [Plugin.roc ...]"

	parse : List(Str) -> Command
	parse = |args|
		match args {
			[] => Help
			[first, ..] =>
				match first {
					"build" => Build(args.drop_first(1))
					"help" => Help
					"version" => Version
					unknown => Unknown(unknown)
				}
			}

	check : List(Str), Cli.Command -> Bool
	check = |args, expected| Cli.parse(args) == expected
}
