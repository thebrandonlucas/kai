# kai's command line, parsed inside the Kaifile with Weaver from the plugins'
# command data, so usage errors and help list what this project defines.
import weaver.Builder
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

	## The parsed command line, or the help or usage text kai shows. Relative
	## `Path` arguments resolve against `directory`, where kai runs.
	parse :
		Command.Page, List(Command), Style, Str, List(Str) -> Try(Parsed, Shown)

	parse = |root, commands, style, directory, argv| {
		parser = match Argv.cli(root, commands, style, directory) {
			Ok(p) => p
			Err(err) => return Err(Usage("invalid commands: ${Str.inspect(err)}"))
		}
		parsed = Cli.parse_or_display_message(parser, argv, |a| Utf8(a))
		top = |config| WeaverHelp.help_text(config, ["kai"], style)
		match parsed {
			Ok(found) => {
				{ file, no_color, json, backend, yes, dry_run, .. } = found
				(name, args) = found.command
				Argv.unknown_name(commands, name, args)?
				Argv.check_choices(commands, name, args).map_err(|why| Usage(why))?
				Ok({
					globals: { file, no_color, json, backend, yes, dry_run },
					command: name,
					args,
				})
			}
			# kai's own help lists each command's summary; a command's page
			# teaches it.
			Err(Help(message)) =>
				if message == top(parser.config) {
					config = parser.config
					shown = top({ ..config, subcommands: Argv.summarized(config) })
					Err(Help(Argv.indented(root, commands, shown)))
				} else {
					Err(Help(Argv.indented(root, commands, Argv.usage(commands, message))))
				}
			Err(Version(message)) => Err(Help(message))
			Err(InvalidUsage(message)) => Err(Usage(Argv.usage(commands, message)))
		}
	}

	## Words outside a `Trailing`'s choices, like a name outside a `Name`'s.
	check_choices : List(Command), Str, Command.Args -> Try({}, Str)
	check_choices = |commands, name, args| {
		for command in commands.keep_if(|c| c.name == name) {
			for arg in command.args {
				match arg {
					Trailing(t) if !t.choices.is_empty() => {
						values = t.choices.map(|c| c.value)
						words = Command.trailing(args, t.name)
						unknown = words.drop_if(|word| values.contains(word))
						if !unknown.is_empty() {
							return Err(
								"kai ${name}: unknown ${Str.join_with(unknown, ", ")}; "
									.concat("the ${t.name} are ${Str.join_with(values, ", ")}"),
							)
						}
					}
					_ => {}
				}
			}
		}
		Ok({})
	}

	cli = |root, commands, style, directory|
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
				command: SubCmd.required(commands.map(|c| Argv.subcommand(c, directory))),
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
						# These list every argument, so they replace Weaver's.
						ours = Argv.arguments(args)
						Str.join_with(
							parts.drop_last(1)
								.drop_if(|part| !ours.is_empty() and part.contains("Arguments:"))
								.concat(ours)
								.concat(parts.take_last(1)),
							"\n\n",
						)
					} else {
						shown
					},
			)

	## Weaver's usage line calls a name's choices COMMAND and lists the words
	## after `--` before them; it names the argument and `--` instead, keeping
	## the options Weaver lists, even when it wraps COMMAND onto a new line.
	## Help lists the choices under their plural, such as Tasks, not Commands.
	usage : List(Command), Str -> Str
	usage = |commands, text|
		commands.fold(
			text,
			|shown, command| {
				start = "kai ${command.name} ["
				{ name, listed, trailing, plural } = command.args.fold(
					{ name: "", listed: "", trailing: "", plural: "" },
					|found, arg|
						match arg {
							Name(n) if !n.choices.is_empty() => {
								choices = "${n.name}s"
								match n.default {
									Required => { ..found, name: " <${n.name}>", plural: choices }
									Default(_) => { ..found, name: " [<${n.name}>]", plural: choices }
								}
							}
							Name(_) => found
							Trailing(t) =>
								{
									..found,
									listed: " [<${t.name}>...]",
									trailing: " [-- <${t.name}>...]",
								}
							_ => found
						},
				)
				if name.is_empty() {
					shown
				} else {
					match shown.split_first(start) {
						Ok({ before, after }) =>
							match after.split_first("COMMAND") {
								Ok(line) => {
									options = line.before
										.drop_suffix("[")
										.drop_suffix("<")
										.drop_suffix("\n  ")
										.drop_suffix(" ")
										.drop_suffix(listed)
									rest = line.after.drop_prefix("]").drop_prefix(">")
									"${before}${start}${options}${name}${trailing}${rest}"
										.replace_each("Commands:", "${Argv.capitalized(plural)}:")
								}
								Err(_) => shown
							}
						Err(_) => shown
					}
				}
			},
		)

	## A word with its first letter in upper case.
	capitalized : Str -> Str
	capitalized = |word|
		match word.to_utf8() {
			[first, .. as rest] if first >= 'a' and first <= 'z' =>
				Str.from_utf8_lossy([first - 'a' + 'A'].concat(rest))
			_ => word
		}

	## The parser keeps a name that is none of its command's choices, so
	## kai can list them.
	unknown_name : List(Command), Str, Command.Args -> Try({}, Shown)
	unknown_name = |commands, command_name, args| {
		for command in commands.keep_if(|c| c.name == command_name) {
			for arg in command.args {
				match arg {
					Name(n) if !n.choices.is_empty() => {
						given = Command.name(args, n.name)
						values = n.choices.map(|c| c.value)
						if !values.contains(given) {
							listed = Str.join_with(values, ", ")
							return Err(
								Usage("no ${n.name} named ${given}; available ${n.name}s: ${listed}"),
							)
						}
					}
					_ => {}
				}
			}
		}
		Ok({})
	}

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
					_ => Bool.False
				},
		)
		# Weaver lists flags and paths as options.
		rows = List.keep_oks(
			args,
			|arg|
				match arg {
					Name(n) => Ok(("<${n.name}>", n.help))
					Trailing(t) => Ok(("<${t.name}...>", t.help))
					_ => Err({})
				},
		)
		width = rows.fold(
			0,
			|widest, (label, _)| widest.max(label.count_utf8_bytes()),
		)
		row = |(label, help)|
			"  ${label}${Str.repeat(" ", width + 2 - label.count_utf8_bytes())}${help}"
		if (chosen) ["Arguments:\n${Str.join_with(rows.map(row), "\n")}"] else []
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

	# A builder that parses nothing, for options to join.
	nothing = |{}|
		Builder.from_arg_parser(|args| Ok({ data: [], remaining_args: args }))

	# One command: a name chosen from its choices (each a subcommand, so help
	# lists them) or any name, then the words after `--`; flags and paths
	# anywhere before `--`.
	subcommand = |command, directory| {
		description = Argv.describe(command.name, command.help)
		given = |name, value| [{ name, value: Present(value) }]
		options = command.args.fold(
			Argv.nothing({}),
			|builder, arg|
				match arg {
					Flag(f) =>
						Cli.weave(
							builder,
							Opt.flag({ short: f.short, long: f.name, help: f.help }),
							|found, set| if (set) found.concat(given(f.name, "")) else found,
						)
					Path(p) =>
						Cli.weave(
							builder,
							Opt.maybe_str({ short: p.short, long: p.name, help: p.help }),
							|found, value|
								match value {
									Ok(path) if path.starts_with("/") => found.concat(given(p.name, path))
									Ok(path) => found.concat(given(p.name, "${directory}/${path}"))
									Err(NoValue) => found
								},
						)
					_ => builder
				},
		)
		finish = |builder|
			SubCmd.finish(
				Cli.weave(options, builder, |found, parsed| parsed.concat(found)),
				{ name: command.name, description, mapper: |args| (command.name, args) },
			)
		# List.keep_oks as a function, not a method: nightly-2026-10-21-5349569
		# gives two calls of one method on one value the same type (roc-issues
		# BUG-016, not reported upstream yet). Use the method once Roc fixes it.
		named = List.keep_oks(
			command.args,
			|arg|
				match arg {
					Name(n) => Ok(n)
					_ => Err({})
				},
		)
		rest = List.keep_oks(
			command.args,
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
			([], []) => finish(Argv.nothing({}))
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
				# List.map as a function: see the BUG-016 note above.
				values = List.map(n.choices, |c| c.value)
				# A word that names no choice reaches `parse`, which lists the
				# choices; a required name cannot be left out.
				missing = |args|
					if n.default == Required {
						Err(NoSubcommandCalled)
					} else {
						Ok({ data: [], remaining_args: args })
					}
				unchosen = Builder.from_arg_parser(
					|args|
						match args {
							[Parameter(word), .. as after] =>
								match word.to_str() {
									Ok(value) if !values.contains(value) =>
										Ok({ data: [picked(n, value)], remaining_args: after })
									_ => Ok({ data: [], remaining_args: args })
								}
							[] => missing(args)
							[PassedThrough(_), ..] => missing(args)
							_ => Ok({ data: [], remaining_args: args })
						},
				)
				# Without a name, the default's words follow `--` directly.
				fallback = match n.default {
					Required => []
					Default(value) => [picked(n, value)]
				}
				# A choice parses its own words; any other name is followed by them.
				name = Cli.weave(
					unchosen,
					SubCmd.optional(choices),
					|unknown, chosen|
						match chosen {
							Ok(parsed) => Ok(parsed)
							Err(_) => Err(if (unknown.is_empty()) fallback else unknown)
						},
				)
				match rest {
					[t, ..] =>
						finish(
							Cli.weave(
								name,
								trailing(t),
								|found, words|
									match found {
										Ok(parsed) => parsed
										Err(other) => other.concat(words)
									},
							),
						)
					[] =>
						finish(
							Cli.map(
								name,
								|found|
									match found {
										Ok(parsed) => parsed
										Err(other) => other
									},
							),
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
				name: "shell",
				help: "",
				choices: choices(["default", "ci"]),
				default: Default("default"),
			}),
			Trailing({ name: "command", help: "", choices: [] }),
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
			Trailing({ name: "args", help: "", choices: [] }),
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
	Argv.parse(page, toy, Plain, "/work", argv).map_ok(|p| (p.command, p.args))

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
	(["shell"], ("shell", [present("shell", "default"), many("command", [])])),
	(
		["shell", "--", "git", "--version"],
		(
			"shell",
			[present("shell", "default"), many("command", ["git", "--version"])],
		),
	),
	(
		["shell", "ci", "--", "git", "--version"],
		("shell", [present("shell", "ci"), many("command", ["git", "--version"])]),
	),
	(["-f", "Kaifile.roc", "update"], ("update", [])),
	(["build", "anything"], ("build", [present("name", "anything")])),
	(
		["--backend", "guix", "shell", "ci", "--", "--backend", "nix"],
		("shell", [present("shell", "ci"), many("command", ["--backend", "nix"])]),
	),
].all(|(argv, expected)| parsed(argv) == Ok(expected))

# Choices reject names the project does not define, listing them; help lists
# commands, and a command's help its choices.
expect
	[["run"], ["build"]].all(
		|argv|
			match parsed(argv) {
				Err(Usage(_)) => Bool.True
				_ => Bool.False
			},
	)
		and parsed(["run", "missing", "--", "x"])
			== Err(Usage("no task named missing; available tasks: args"))
		and parsed(["shell", "missing"])
			== Err(Usage("no shell named missing; available shells: default, ci"))
		and match parsed(["--help"]) {
			Err(Help(text)) => text.contains("shell") and text.contains("About.")
			_ => Bool.False
		}
		and match parsed(["run", "--help"]) {
			Err(Help(text)) => text.contains("Tasks:") and !text.contains("Commands:")
			_ => Bool.False
		}

# Usage lines name the argument and the words after `--`, keeping the options
# Weaver lists even when it wraps the line.
expect {
	build = Command.{
		name: "build",
		summary: "",
		help: page,
		args: [
			Name(
				{ name: "build", help: "", choices: choices(["a"]), default: Required },
			),
			Flag({ name: "print-build-logs", short: "L", help: "" }),
			Path({ name: "out-link", short: "", help: "" }),
		],
		lock: ReadsLock,
	}
	usage_of = |commands, argv|
		match Argv.parse(page, commands, Plain, "/work", argv) {
			Err(Help(text)) => text
			_ => ""
		}
	usage_of([build], ["build", "--help"]).contains(
		"kai build [-L/--print-build-logs] [--out-link STR] [-h/--help] "
			.concat("[-V/--version] <build>\n"),
	)
		and usage_of(toy, ["shell", "--help"]).contains(
			"kai shell [-h/--help] [-V/--version] [<shell>] [-- <command>...]\n",
		)
}
