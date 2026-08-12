# Pure command-line parsing for Kai's private development tool.
Cli := [].{
	Command := [BuildRelease, Help, PrepareRelease({ name : Str, version : Str })].{
		is_eq : Command, Command -> Bool
		is_eq = |left, right|
			match (left, right) {
				(BuildRelease, BuildRelease) => Bool.True
				(Help, Help) => Bool.True
				(PrepareRelease(left_args), PrepareRelease(right_args))
					=> left_args == right_args
				_ => Bool.False
			}
	}

	Error := [ArgumentsNotAllowed(Str), ExpectedArguments(Str), UnknownCommand(Str)].{
		is_eq : Error, Error -> Bool
		is_eq = |left, right|
			match (left, right) {
				(ArgumentsNotAllowed(left_name), ArgumentsNotAllowed(right_name))
					=> left_name == right_name
				(ExpectedArguments(left_name), ExpectedArguments(right_name))
					=> left_name == right_name
				(UnknownCommand(left_name), UnknownCommand(right_name))
					=> left_name == right_name
				_ => Bool.False
			}
	}

	usage : Str
	usage = "Usage: kai-devtool <command> [arguments]\n\nCommands:\n  build-release\n  prepare-release NAME VERSION\n  help"

	parse : List(Str) -> Try(Command, Error)
	parse = |args|
		match args {
			[] => Ok(Help)
			["help"] => Ok(Help)
			["build-release"] => Ok(BuildRelease)
			["prepare-release", name, version] => Ok(PrepareRelease({ name, version }))
			[first, ..] =>
				match first {
					"help" => Err(ArgumentsNotAllowed(first))
					"build-release" => Err(ArgumentsNotAllowed(first))
					"prepare-release" => Err(ExpectedArguments(first))
					unknown => Err(UnknownCommand(unknown))
				}
			}

	error_message : Error -> Str
	error_message = |error|
		match error {
			ArgumentsNotAllowed(command) => "${command} does not accept arguments"
			ExpectedArguments(command) => "${command} requires NAME and VERSION"
			UnknownCommand(command) => "unknown command: ${command}"
		}

	check : List(Str), Try(Command, Error) -> Bool
	check = |args, expected|
		match (Cli.parse(args), expected) {
			(Ok(actual_command), Ok(expected_command))
				=> actual_command == expected_command
			(Err(actual_error), Err(expected_error))
				=> actual_error == expected_error
			_ => Bool.False
		}
}
