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
	# plugins define the rest of the commands. It reads and is colored like
	# the page the platform's Weaver shows for a Kaifile.roc.
	generic : Str, Str, [Color, Plain] -> Str
	generic = |version, why, style| {
		name = |text| Help.styled(style, ["1", "36"], text)
		heading = |text| Help.styled(style, ["1", "4", "36"], text)
		# Each name padded to `width`, its wrapped lines aligned after it.
		rows = |width, entries| {
			indent = Str.repeat(" ", width + 2)
			row = |(label, lines)| {
				gap = Str.repeat(" ", width - label.count_utf8_bytes())
				"  ${name(label)}${gap}${Str.join_with(lines, "\n${indent}")}"
			}
			Str.join_with(entries.map(row), "\n")
		}
		usage = name(
			"  kai [-f/--file STR] [--no-color] [--json] [--backend STR] "
				.concat("[--yes] [--dry-run]\n")
				.concat("  [-h/--help] [-V/--version] <COMMAND>"),
		)
		commands = rows(
			10,
			[
				(
					"check",
					[
						"Compile Kaifile.roc and report whether its configuration is valid,",
						"without building or running anything.",
					],
				),
				(
					"describe",
					[
						"List the plugins, commands and backends Kaifile.roc defines, for",
						"people and, with --json, for tools.",
					],
				),
			],
		)
		options = rows(
			20,
			[
				(
					"-f STR, --file STR",
					["Read configuration from PATH (default: Kaifile.roc)."],
				),
				("--no-color", ["Print plain text without colors."]),
				("--json", ["Print kai's own output as JSON Lines."]),
				(
					"--backend STR",
					["Use this backend instead of choosing automatically."],
				),
				("--yes", ["Answer yes to every confirmation."]),
				("--dry-run", ["Print the plan instead of running it."]),
				("-h, --help", ["Show this help page."]),
				("-V, --version", ["Show the version."]),
			],
		)
		\\${name("kai")} ${version}
		\\
		\\Developer environments, tasks and builds from a Kaifile.roc.
		\\
		\\Examples:
		\\  kai check
		\\  kai update
		\\  kai shell
		\\  kai run test
		\\
		\\Kaifile.roc (inside Std.kaifile):
		\\  Environment("dev", [Tools(["git"])]),
		\\  Shell("default", [Use("dev")]),
		\\  Task("test", [Use("dev"), Run(["git", "--version"])]),
		\\
		\\${why}
		\\
		\\${heading("Usage:")}
		\\${usage}
		\\
		\\${heading("Commands:")}
		\\${commands}
		\\
		\\A Kaifile.roc's plugins add the other commands: std adds shell, run, build,
		\\workflow, update and model.
		\\
		\\${heading("Options:")}
		\\${options}
		\\
		\\${Help.notes}
	}

	# Text in Weaver's terminal styles, or as it is when color is off.
	styled : [Color, Plain], List(Str), Str -> Str
	styled = |style, codes, text|
		match style {
			Color => {
				escapes = codes.map(|code| "\u(001b)[${code}m")
				"${Str.join_with(escapes, "")}${text}\u(001b)[0m"
			}
			Plain => text
		}

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

# The generic page is plain without color and styled like Weaver's with it.
expect {
	plain = Help.generic("1.0", "No Kaifile.roc.", Plain)
	colored = Help.generic("1.0", "No Kaifile.roc.", Color)
	!plain.contains("\u(001b)")
		and plain.starts_with("kai 1.0\n")
			and colored.contains("\u(001b)[1m\u(001b)[4m\u(001b)[36mUsage:\u(001b)[0m")
}
