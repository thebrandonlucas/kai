app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
}

import pf.OsStr
import pf.Stdout

import Cli

main! : List(OsStr) => Try({}, _)
main! = |args|
	match Cli.parse(args.drop_first(1).map(OsStr.display)) {
		Ok(Cli.Command.Help) => Stdout.line!(Cli.usage)
		Ok(Cli.Command.BuildRelease) => Err(NotYetImplemented("build-release"))
		Ok(Cli.Command.PrepareRelease(_)) => Err(NotYetImplemented("prepare-release"))
		Ok(Cli.Command.PublishRelease) => Err(NotYetImplemented("publish-release"))
		Err(error) => Err(InvalidArguments(Cli.error_message(error)))
	}

## -- TESTS --

parse_cases = [
	{ args: [], expected: Ok(Cli.Command.Help) },
	{ args: ["help"], expected: Ok(Cli.Command.Help) },
	{ args: ["build-release"], expected: Ok(Cli.Command.BuildRelease) },
	{
		args: ["prepare-release", "μοριων", "0.0.3"],
		expected: Ok(Cli.Command.PrepareRelease({ name: "μοριων", version: "0.0.3" })),
	},
	{ args: ["publish-release"], expected: Ok(Cli.Command.PublishRelease) },
	{
		args: ["build-release", "extra"],
		expected: Err(Cli.Error.ArgumentsNotAllowed("build-release")),
	},
	{
		args: ["publish-release", "extra"],
		expected: Err(Cli.Error.ArgumentsNotAllowed("publish-release")),
	},
	{
		args: ["prepare-release", "only-name"],
		expected: Err(Cli.Error.ExpectedArguments("prepare-release")),
	},
	{ args: ["unknown"], expected: Err(Cli.Error.UnknownCommand("unknown")) },
]

usage_lines = [
	"Usage: kai-devtool <command> [arguments]",
	"build-release",
	"prepare-release NAME VERSION",
	"publish-release",
	"help",
]

expect List.all(parse_cases, |case| Cli.check(case.args, case.expected))
expect List.all(usage_lines, |line| Cli.usage.contains(line))
