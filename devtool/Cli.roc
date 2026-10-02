# Pure command-line parsing for Kai's private development tool.
Cli := [].{

	## An end-to-end test run: one test or `all`, on both backends unless
	## --nix or --guix picks one. Nix halves run the Nix-installed kai, Guix
	## halves the bare one, as a release archive holds it.
	E2eRun : {
		test : Str,
		only : [Both, Nix, Guix],
		require_guix : Bool,
		kai : Str,
		bare : Str,
	}

	Command := [
		BuildRelease,
		ConfigFixtures,
		E2e(E2eRun),
		Fuzz({ seconds : Str, apps : List(Str) }),
		Help,
		PrepareRelease({ name : Str, version : Str }),
		Tidy(List(Str)),
	].{
		is_eq : Command, Command -> Bool
		is_eq = |left, right|
			match (left, right) {
				(BuildRelease, BuildRelease) => Bool.True
				(ConfigFixtures, ConfigFixtures) => Bool.True
				(E2e(left_run), E2e(right_run)) => left_run == right_run
				(Fuzz(left_args), Fuzz(right_args)) => left_args == right_args
				(Help, Help) => Bool.True
				(PrepareRelease(left_args), PrepareRelease(right_args))
					=> left_args == right_args
				(Tidy(left_paths), Tidy(right_paths)) => left_paths == right_paths
				_ => Bool.False
			}
	}

	Error := [
		ArgumentsNotAllowed(Str),
		ExpectedArguments(Str),
		ExpectedKaiBinaries,
		UnknownCommand(Str),
		UnknownOption(Str),
		UnknownTest(Str),
	].{
		is_eq : Error, Error -> Bool
		is_eq = |left, right|
			match (left, right) {
				(ArgumentsNotAllowed(left_name), ArgumentsNotAllowed(right_name))
					=> left_name == right_name
				(ExpectedArguments(left_name), ExpectedArguments(right_name))
					=> left_name == right_name
				(ExpectedKaiBinaries, ExpectedKaiBinaries) => Bool.True
				(UnknownCommand(left_name), UnknownCommand(right_name))
					=> left_name == right_name
				(UnknownOption(left_name), UnknownOption(right_name))
					=> left_name == right_name
				(UnknownTest(left_name), UnknownTest(right_name))
					=> left_name == right_name
				_ => Bool.False
			}
	}

	## The end-to-end tests, in the order `all` runs them. run, build,
	## workflow and update have a Guix half; the rest run on Nix only.
	e2e_tests : List(Str)
	e2e_tests = [
		"run",
		"build",
		"workflow",
		"update",
		"overlays",
		"help",
		"plugins",
		"bundle",
	]

	usage : Str
	usage =
		\\Usage: kai-devtool <command> [arguments]
		\\
		\\Commands:
		\\  build-release
		\\  config-fixtures
		\\  e2e TEST [--nix | --guix] [--require-guix] KAI_BINARY BARE_KAI_BINARY
		\\      TEST is all, run, build, workflow, update, overlays, help,
		\\      plugins or bundle
		\\  fuzz SECONDS ROC_APP...
		\\  prepare-release NAME VERSION
		\\  tidy [ROC_FILE...]
		\\  help

	parse : List(Str) -> Try(Command, Error)
	parse = |args|
		match args {
			[] => Ok(Help)
			["help"] => Ok(Help)
			["build-release"] => Ok(BuildRelease)
			["config-fixtures"] => Ok(ConfigFixtures)
			["e2e", test, .. as rest] => Cli.e2e(test, rest)
			["fuzz", seconds, first_app, .. as apps] =>
				Ok(Fuzz({ seconds, apps: [first_app].concat(apps) }))
			["prepare-release", name, version] => Ok(PrepareRelease({ name, version }))
			["tidy", .. as paths] => Ok(Tidy(paths))
			[first, ..] =>
				match first {
					"help" => Err(ArgumentsNotAllowed(first))
					"build-release" => Err(ArgumentsNotAllowed(first))
					"config-fixtures" => Err(ArgumentsNotAllowed(first))
					"fuzz" | "prepare-release" => Err(ExpectedArguments(first))
					"e2e" => Err(ExpectedKaiBinaries)
					unknown => Err(UnknownCommand(unknown))
				}
			}

	## Backend flags may come in any order before the two binaries; both
	## --nix and --guix together mean both backends.
	e2e : Str, List(Str) -> Try(Command, Error)
	e2e = |test, rest| {
		if test != "all" and !Cli.e2e_tests.contains(test) {
			return Err(UnknownTest(test))
		}
		var $nix = Bool.False
		var $guix = Bool.False
		var $require_guix = Bool.False
		var $binaries = []
		for arg in rest {
			if arg == "--nix" {
				$nix = Bool.True
			} else if arg == "--guix" {
				$guix = Bool.True
			} else if arg == "--require-guix" {
				$require_guix = Bool.True
			} else if arg.starts_with("--") {
				return Err(UnknownOption(arg))
			} else {
				$binaries = $binaries.append(arg)
			}
		}
		only = if $nix and !$guix Nix else if $guix and !$nix Guix else Both
		match $binaries {
			[kai, bare] =>
				Ok(E2e({ test, only, require_guix: $require_guix, kai, bare }))
			_ => Err(ExpectedKaiBinaries)
		}
	}

	error_message : Error -> Str
	error_message = |error|
		match error {
			ArgumentsNotAllowed(command) => "${command} does not accept arguments"
			ExpectedArguments(command) => "${command} requires NAME and VERSION"
			ExpectedKaiBinaries => "e2e requires KAI_BINARY and BARE_KAI_BINARY"
			UnknownCommand(command) => "unknown command: ${command}"
			UnknownOption(option) => "unknown option: ${option}"
			UnknownTest(test) => "unknown e2e test: ${test}"
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
