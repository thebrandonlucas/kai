# kai's command line, parsed inside the Kaifile with Weaver from the plugins'
# command data, so usage errors and help list what this project defines.
import weaver.Cli
import weaver.Help as WeaverHelp
import weaver.Opt
import weaver.Param
import weaver.SubCmd
import Command

Argv := [].{

	## kai's own flags, which kai also finds before running the Kaifile.
	Globals : {
		file : Try(Str, [NoValue]),
		no_color : Bool,
		json : Bool,
		backend : Try(Str, [NoValue]),
		yes : Bool,
		dry_run : Bool,
	}

	Parsed : { globals : Globals, command : Str, args : Command.Args }

	Style : [Color, Plain]

	## What kai prints instead of running a command.
	Shown : [Help(Str), Usage(Str)]

	## The parsed command line, or the help or usage text kai shows.
	parse : Command.Page, List(Command), Style, List(Str) -> Try(Parsed, Shown)

	parse = |root, commands, style, argv| {
		parser = match Argv.cli(root, commands, style) {
			Ok(p) => p
			Err(err) => return Err(Usage("invalid commands: ${Str.inspect(err)}"))
		}
		parsed = Cli.parse_or_display_message(parser, argv, |a| Utf8(a))
		top = |config| WeaverHelp.help_text(config, ["kai"], style)
		match parsed {
			Ok({ file, no_color, json, backend, yes, dry_run, command: (name, args) }) =>
				Ok({
					globals: { file, no_color, json, backend, yes, dry_run },
					command: name,
					args,
				})
			# kai's own help lists each command's summary; a command's page
			# teaches it.
			Err(Help(message)) =>
				if message == top(parser.config) {
					config = parser.config
					shown = top({ ..config, subcommands: Argv.summarized(config) })
					Err(Help(Argv.indented(root, commands, shown)))
				} else {
					Err(Help(Argv.indented(root, commands, message)))
				}
			Err(Version(message)) => Err(Help(message))
			Err(InvalidUsage(message)) => Err(Usage(message))
		}
	}

	cli = |root, commands, style|
		Cli.finish(
			{
				file: Opt.maybe_str({
					short: "f",
					long: "file",
					help: "Read configuration from PATH (default: Kaifile.roc).",
				}),
				no_color: Opt.flag({
					short: "",
					long: "no-color",
					help: "Print plain text without colors.",
				}),
				json: Opt.flag({
					short: "",
					long: "json",
					help: "Print kai's own output as JSON Lines.",
				}),
				backend: Opt.maybe_str({
					short: "",
					long: "backend",
					help: "Use this backend instead of choosing automatically.",
				}),
				yes: Opt.flag({
					short: "",
					long: "yes",
					help: "Answer yes to every confirmation.",
				}),
				dry_run: Opt.flag({
					short: "",
					long: "dry-run",
					help: "Print the plan instead of running it.",
				}),
				command: SubCmd.required(commands.map(Argv.subcommand)),
			}.Cli,
			{
				name: "kai",
				version: "",
				authors: [],
				description: Argv.describe("kai", root),
				text_style: style,
			},
		)

	## A page as Weaver shows it: its description, then a one-word marker that
	## `indented` replaces with the page's sections, because Weaver drops
	## leading spaces. A parent shows only the first paragraph.
	describe : Str, Command.Page -> Str
	describe = |name, page|
		if page.examples.is_empty() and page.config.is_empty() {
			page.description
		} else {
			"${page.description}\n\n${Argv.marker(name)}"
		}

	marker : Str -> Str
	marker = |name| "<kai-help:${name}>"

	## The shown page's marker becomes its indented sections, and the page
	## names its arguments when Weaver lists a name's choices instead.
	indented : Command.Page, List(Command), Str -> Str
	indented = |root, commands, text|
		[("kai", root, [])]
			.concat(commands.map(|c| (c.name, c.help, c.args)))
			.fold(
				text,
				|shown, (name, page, args)|
					if shown.contains(Argv.marker(name)) {
						# Options, always present, end the page.
						parts = shown
							.replace_each(Argv.marker(name), Argv.sections(page))
							.split_on("\n\n")
						Str.join_with(
							parts.drop_last(1)
								.concat(Argv.arguments(args))
								.concat(parts.take_last(1)),
							"\n\n",
						)
					} else {
						shown
					},
			)

	sections : Command.Page -> Str
	sections = |page| {
		section = |heading, lines|
			if lines.is_empty() {
				[]
			} else {
				[Str.join_with([heading].concat(lines.map(|line| "  ${line}")), "\n")]
			}
		Str.join_with(
			section("Examples:", page.examples)
				.concat(section("Kaifile.roc (inside Std.kaifile):", page.config)),
			"\n\n",
		)
	}

	arguments : List(Command.Arg) -> List(Str)
	arguments = |args| {
		chosen = args.any(
			|arg|
				match arg {
					Name(n) => !n.choices.is_empty()
					Trailing(_) => Bool.False
				},
		)
		rows = args.map(
			|arg|
				match arg {
					Name(n) => ("<${n.name}>", n.help)
					Trailing(t) => ("<${t.name}...>", t.help)
				},
		)
		width = rows.fold(
			0,
			|widest, (label, _)| widest.max(label.count_utf8_bytes()),
		)
		row = |(label, help)|
			"  ${label}${Str.repeat(" ", width + 2 - label.count_utf8_bytes())}${help}"
		if chosen ["Arguments:\n${Str.join_with(rows.map(row), "\n")}"] else []
	}

	summary : Str -> Str
	summary = |description| description.split_on("\n\n").first() ?? description

	summarized = |config|
		match config.subcommands {
			HasSubcommands({ commands, required }) =>
				HasSubcommands({
					commands: commands.map(
						|(name, command)|
							(name, { ..command, description: Argv.summary(command.description) }),
					),
					required,
				})
			NoSubcommands => NoSubcommands
		}

	# One command: a name chosen from its choices (each a subcommand, so help
	# lists them) or any name, then the words after `--`.
	subcommand = |command| {
		description = Argv.describe(command.name, command.help)
		finish = |builder|
			SubCmd.finish(
				builder,
				{ name: command.name, description, mapper: |args| (command.name, args) },
			)
		named = command.args.keep_oks(
			|arg|
				match arg {
					Name(n) => Ok(n)
					_ => Err({})
				},
		)
		rest = command.args.keep_oks(
			|arg|
				match arg {
					Trailing(t) => Ok(t)
					_ => Err({})
				},
		)
		trailing = |t|
			Cli.map(
				Param.str_list({ name: t.name, help: t.help }),
				|words| [{ name: t.name, value: Many(words) }],
			)
		picked = |n, value| { name: n.name, value: Present(value) }
		match (named, rest) {
			([], []) =>
				SubCmd.empty({ name: command.name, description, value: (command.name, []) })
			([], [t, ..]) => finish(trailing(t))
			([n, ..], _) if !n.choices.is_empty() => {
				choice = |c| {
					about = Str.join_with([c.summary].concat(c.details), "\n")
					match rest {
						[t, ..] =>
							SubCmd.finish(
								trailing(t),
								{
									name: c.value,
									description: about,
									mapper: |words| [picked(n, c.value)].concat(words),
								},
							)
						[] =>
							SubCmd.empty({
								name: c.value,
								description: about,
								value: [picked(n, c.value)],
							})
						}
				}
				choices = n.choices.map(choice)
				match n.default {
					Required => finish(SubCmd.required(choices))
					Default(value) =>
						finish(
							Cli.map(SubCmd.optional(choices), |p| p ?? [picked(n, value)]),
						)
					}
			}
			([n, ..], _) => {
				name = match n.default {
					Required =>
						Cli.map(
							Param.str({ name: n.name, help: n.help, default: NoDefault }),
							|value| [picked(n, value)],
						)
					Default(fallback) =>
						Cli.map(
							Param.maybe_str({ name: n.name, help: n.help }),
							|value| [picked(n, value ?? fallback)],
						)
					}
				match rest {
					[t, ..] => finish(Cli.weave(name, trailing(t), |a, b| a.concat(b)))
					[] => finish(name)
				}
			}
		}
	}
}

page : Command.Page
page = { description: "About.", examples: ["kai x"], config: ["X(\"x\"),"] }

choices : List(Str) -> List(Command.Choice)
choices = |names| names.map(|value| { value, summary: "", details: [] })

toy : List(Command)
toy = [
	Command.{
		name: "shell",
		summary: "",
		help: page,
		args: [
			Name({
				name: "name",
				help: "",
				choices: choices(["default", "ci"]),
				default: Default("default"),
			}),
			Trailing({ name: "command", help: "" }),
		],
		lock: ReadsLock,
	},
	Command.{
		name: "run",
		summary: "",
		help: page,
		args: [
			Name({
				name: "task",
				help: "",
				choices: choices(["args"]),
				default: Required,
			}),
			Trailing({ name: "args", help: "" }),
		],
		lock: ReadsLock,
	},
	Command.{
		name: "build",
		summary: "",
		help: page,
		args: [Name({ name: "name", help: "", choices: [], default: Required })],
		lock: ReadsLock,
	},
	Command.{ name: "update", summary: "", help: page, args: [], lock: OwnsLock },
]

parsed = |argv|
	Argv.parse(page, toy, Plain, argv).map_ok(|p| (p.command, p.args))

present = |name, value| { name, value: Present(value) }

many = |name, words| { name, value: Many(words) }

# Arguments after -- reach the task or shell command exactly, never kai;
# kai's own flags are found anywhere before --.
expect [
	(
		["run", "args", "--", "--json", "--yes"],
		("run", [present("task", "args"), many("args", ["--json", "--yes"])]),
	),
	(
		["run", "args", "--", "first", "two words", "--literal", ""],
		(
			"run",
			[
				present("task", "args"),
				many("args", ["first", "two words", "--literal", ""]),
			],
		),
	),
	(["shell"], ("shell", [present("name", "default")])),
	(
		["shell", "ci", "--", "git", "--version"],
		("shell", [present("name", "ci"), many("command", ["git", "--version"])]),
	),
	(["-f", "Kaifile.roc", "update"], ("update", [])),
	(["build", "anything"], ("build", [present("name", "anything")])),
	(
		["--backend", "guix", "shell", "ci", "--", "--backend", "nix"],
		("shell", [present("name", "ci"), many("command", ["--backend", "nix"])]),
	),
].all(|(argv, expected)| parsed(argv) == Ok(expected))

# Choices reject names the project does not define; help lists commands.
expect
	[["run", "missing"], ["shell", "missing"], ["run"], ["build"]].all(
		|argv|
			match parsed(argv) {
				Err(Usage(_)) => Bool.True
				_ => Bool.False
			},
	)
		and match parsed(["--help"]) {
			Err(Help(text)) => text.contains("shell") and text.contains("About.")
			_ => Bool.False
		}
