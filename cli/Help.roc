# kai's own help: the header a Kaifile.roc starts with, and what kai says
# when there is no Kaifile.roc to ask. Command help comes from the Kaifile's
# plugins.
import "../platform-release" as platform_release : Str
import "../plugins/std-release" as std_release : Str

Help := [].{
	# How a Kaifile.roc starts: with the platform and std bundles this Kai's
	# release publishes. Each URL is one unbroken line, however help wraps.
	header =
		\\  app [kaifile] {
		\\      pf: platform "${platform_release.trim()}",
		\\      std: "${std_release.trim()}",
		\\  }
		\\
		\\  import std.Std
		\\
		\\  kaifile = Std.kaifile([...])

	# What kai's own help ends with, with or without a Kaifile.roc.
	notes =
		\\Kaifile.roc starts with:
		\\${Help.header}
		\\
		\\Put arguments for a shell command or task after --.
		\\Set ROC to choose the Roc compiler (default: roc).

	# The Kaifile cannot know kai's version, so kai adds it to the title.
	versioned : Str, Str -> Str
	versioned = |text, version|
		match text.split_first("\n") {
			Ok({ before, after }) => "${before} ${version}\n${after}"
			Err(_) => text
		}

	# Shown when Kaifile.roc is missing or does not compile, since its
	# plugins define the rest of the commands.
	generic : Str, Str -> Str
	generic = |version, why|
		\\kai ${version}
		\\
		\\Developer environments, tasks and builds from a Kaifile.roc.
		\\
		\\${why}
		\\
		\\Usage:
		\\  kai [OPTIONS] <COMMAND>
		\\
		\\Commands:
		\\  check     Compile Kaifile.roc and report whether it is valid.
		\\  describe  List the plugins, commands and backends Kaifile.roc defines.
		\\
		\\A Kaifile.roc's plugins add the other commands: std adds shell, run, build,
		\\workflow, update and model.
		\\
		\\Options:
		\\  -f STR, --file STR  Read configuration from PATH (default: Kaifile.roc).
		\\  --no-color          Print plain text without colors.
		\\  --json              Print kai's own output as JSON Lines.
		\\  --backend STR       Use this backend instead of choosing automatically.
		\\  --yes               Answer yes to every confirmation.
		\\  --dry-run           Print the plan instead of running it.
		\\  -h, --help          Show this help page.
		\\  -V, --version       Show the version.
		\\
		\\${Help.notes}

	# Color is decoration only: NO_COLOR (when non-empty), --no-color or output
	# that is not a terminal all get plain text.
	text_style : { terminal : Bool, no_color : Str, flag : Bool } -> [Color, Plain]
	text_style = |{ terminal, no_color, flag }|
		if terminal and no_color.is_empty() and !flag Color else Plain
}

# Only an interactive terminal without an opt-out gets color.
expect [
	({ terminal: Bool.True, no_color: "", flag: Bool.False }, Color),
	({ terminal: Bool.False, no_color: "", flag: Bool.False }, Plain),
	({ terminal: Bool.True, no_color: "1", flag: Bool.False }, Plain),
	({ terminal: Bool.True, no_color: "", flag: Bool.True }, Plain),
	({ terminal: Bool.False, no_color: "1", flag: Bool.True }, Plain),
].all(|(input, expected)| Help.text_style(input) == expected)
