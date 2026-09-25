# Pure command-line parsing for Kai's private development tool.
Cli := [].{
	Command := [
		BuildRelease,
		ConfigFixtures,
		Help,
		KaiUpdate(Str),
		Kaifiles,
		KaifilesSmoke,
		PrepareRelease({ name : Str, version : Str }),
		PrepareXkai({ bundle_dir : Str, output_dir : Str, source_dir : Str }),
		Tidy(List(Str)),
	].{
		is_eq : Command, Command -> Bool
		is_eq = |left, right|
			match (left, right) {
				(BuildRelease, BuildRelease) => Bool.True
				(ConfigFixtures, ConfigFixtures) => Bool.True
				(Help, Help) => Bool.True
				(KaiUpdate(left_kai), KaiUpdate(right_kai)) => left_kai == right_kai
				(Kaifiles, Kaifiles) => Bool.True
				(KaifilesSmoke, KaifilesSmoke) => Bool.True
				(PrepareRelease(left_args), PrepareRelease(right_args))
					=> left_args == right_args
				(PrepareXkai(left_args), PrepareXkai(right_args))
					=> left_args == right_args
				(Tidy(left_paths), Tidy(right_paths)) => left_paths == right_paths
				_ => Bool.False
			}
	}

	Error := [
		ArgumentsNotAllowed(Str),
		ExpectedArguments(Str),
		ExpectedKaiBinary,
		ExpectedPrepareXkaiArguments,
		UnknownCommand(Str),
	].{
		is_eq : Error, Error -> Bool
		is_eq = |left, right|
			match (left, right) {
				(ArgumentsNotAllowed(left_name), ArgumentsNotAllowed(right_name))
					=> left_name == right_name
				(ExpectedArguments(left_name), ExpectedArguments(right_name))
					=> left_name == right_name
				(ExpectedKaiBinary, ExpectedKaiBinary) => Bool.True
				(ExpectedPrepareXkaiArguments, ExpectedPrepareXkaiArguments)
					=> Bool.True
				(UnknownCommand(left_name), UnknownCommand(right_name))
					=> left_name == right_name
				_ => Bool.False
			}
	}

	usage : Str
	usage =
		\\Usage: kai-devtool <command> [arguments]
		\\
		\\Commands:
		\\  build-release
		\\  config-fixtures
		\\  kaifiles
		\\  kai-update KAI_BINARY
		\\  prepare-release NAME VERSION
		\\  prepare-xkai BUNDLE_DIR SOURCE_DIR OUTPUT_DIR
		\\  tidy [ROC_FILE...]
		\\  help

	parse : List(Str) -> Try(Command, Error)
	parse = |args|
		match args {
			[] => Ok(Help)
			["help"] => Ok(Help)
			["build-release"] => Ok(BuildRelease)
			["config-fixtures"] => Ok(ConfigFixtures)
			["kaifiles"] => Ok(Kaifiles)
			["kaifiles-smoke"] => Ok(KaifilesSmoke)
			["kai-update", kai] => Ok(KaiUpdate(kai))
			["prepare-release", name, version] => Ok(PrepareRelease({ name, version }))
			["prepare-xkai", bundle_dir, source_dir, output_dir] => Ok(
				PrepareXkai({ bundle_dir, output_dir, source_dir }),
			)
			["tidy", .. as paths] => Ok(Tidy(paths))
			[first, ..] =>
				match first {
					"help" => Err(ArgumentsNotAllowed(first))
					"build-release" => Err(ArgumentsNotAllowed(first))
					"config-fixtures" => Err(ArgumentsNotAllowed(first))
					"kaifiles" => Err(ArgumentsNotAllowed(first))
					"kaifiles-smoke" => Err(ArgumentsNotAllowed(first))
					"prepare-release" => Err(ExpectedArguments(first))
					"kai-update" => Err(ExpectedKaiBinary)
					"prepare-xkai" => Err(ExpectedPrepareXkaiArguments)
					unknown => Err(UnknownCommand(unknown))
				}
			}

	error_message : Error -> Str
	error_message = |error|
		match error {
			ArgumentsNotAllowed(command) => "${command} does not accept arguments"
			ExpectedArguments(command) => "${command} requires NAME and VERSION"
			ExpectedKaiBinary => "kai-update requires KAI_BINARY"
			ExpectedPrepareXkaiArguments =>
				"prepare-xkai requires BUNDLE_DIR SOURCE_DIR OUTPUT_DIR"
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
