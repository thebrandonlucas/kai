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
			# teaches it and lists each of its choices' summaries, whose own
			# page shows its details too.
			Err(Help(message)) =>
				if message == top(parser.config) {
					config = parser.config
					shown = top({ ..config, subcommands: Argv.summarized(config) })
					Err(Help(Argv.indented(root, commands, shown)))
				} else {
					shown = Argv.listed(parser.config, commands, style, message)
					Err(Help(Argv.indented(root, commands, Argv.usage(commands, shown))))
				}
			Err(Version(message)) => Err(Help(message))
			Err(InvalidUsage(message)) =>
				match Argv.misnamed(commands, argv, message) {
					Ok(why) => Err(Usage(why))
					Err(NotMisnamed) => Err(Usage(Argv.usage(commands, message)))
				}
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
					help: "Print kai's own output as JSON Lines on stderr.",
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
	## kai can list them, and suggest the closest.
	unknown_name : List(Command), Str, Command.Args -> Try({}, Shown)
	unknown_name = |commands, command_name, args|
		match Argv.chosen_name(commands, command_name) {
			Ok({ name, values }) if !values.is_empty() => {
				given = Command.name(args, name)
				if values.contains(given) {
					Ok({})
				} else {
					offered = Argv.offered(name, given, values)
					Err(Usage("no ${name} named ${given}; ${offered}"))
				}
			}
			_ => Ok({})
		}

	## The name a command takes, such as run's task, and its choices.
	chosen_name :
		List(Command), Str -> Try({ name : Str, values : List(Str) }, [NoName])
	chosen_name = |commands, command_name| {
		for command in commands.keep_if(|c| c.name == command_name) {
			for arg in command.args {
				match arg {
					Name(n) =>
						return Ok({ name: n.name, values: n.choices.map(|c| c.value) })
					_ => {}
				}
			}
		}
		Err(NoName)
	}

	## The available names, then the closest to a mistyped `given`, if any.
	offered : Str, Str, List(Str) -> Str
	offered = |name, given, values| {
		listed = "available ${name}s: ${Str.join_with(values, ", ")}"
		match Argv.closest(given, values) {
			[] => listed
			close => {
				quoted = close.map(|c| "`${c}`")
				"${listed}; did you mean ${Str.join_with(quoted, " or ")}?"
			}
		}
	}

	## Instead of Weaver's report, the words kai uses for a missing name or an
	## unknown command, as for an unknown name.
	misnamed : List(Command), List(Str), Str -> Try(Str, [NotMisnamed])
	misnamed = |commands, argv, message| {
		names = commands.map(|c| c.name)
		unrecognized = message.contains("The subcommand")
		missing = message.contains("A subcommand must be called")
			or message.contains("did not receive a value")
		match Argv.positional(commands, argv) {
			[given, ..] if unrecognized and !names.contains(given) =>
				Ok("no command named ${given}; ${Argv.offered("command", given, names)}")
			[given] if missing =>
				match Argv.chosen_name(commands, given) {
					Ok({ name, values }) if values.is_empty() =>
						Ok("kai ${given} needs a ${name}")
					Ok({ name, values }) =>
						Ok("kai ${given} needs a ${name}; ${Argv.offered(name, "", values)}")
					Err(NoName) => Err(NotMisnamed)
				}
			_ => Err(NotMisnamed)
		}
	}

	## The words before `--` that are neither options nor their values.
	positional : List(Command), List(Str) -> List(Str)
	positional = |commands, argv| {
		paths = commands.join_map(
			|c|
				c.args.join_map(
					|arg|
						match arg {
							Path(p) => ["--${p.name}", "-${p.short}"]
							_ => []
						},
				),
		)
		Argv.positional_after(["-f", "--file", "--backend"].concat(paths), argv)
	}

	positional_after : List(Str), List(Str) -> List(Str)
	positional_after = |valued, argv|
		match argv {
			[] | ["--", ..] => []
			[option, _, .. as rest] if valued.contains(option) =>
				Argv.positional_after(valued, rest)
			[arg, .. as rest] if arg.starts_with("-") =>
				Argv.positional_after(valued, rest)
			[word, .. as rest] => [word].concat(Argv.positional_after(valued, rest))
		}

	## The names closest to a mistyped `given`: at most two edits away, and
	## fewer edits than it has letters.
	closest : Str, List(Str) -> List(Str)
	closest = |given, names| {
		scored = names.map(|name| (name, Argv.distance(given, name)))
		best = scored.fold(3, |lowest, (_, edits)| lowest.min(edits))
		limit = given.count_utf8_bytes().min(3)
		scored.keep_if(|(_, edits)| edits == best and edits < limit)
			.map(|(name, _)| name)
	}

	## How many one-byte insertions, deletions or replacements turn `a` into
	## `b` (Levenshtein distance).
	distance : Str, Str -> U64
	distance = |a, b| {
		right = b.to_utf8()
		var $previous = []
		var $count = 0
		for _ in [0].concat(right) {
			$previous = $previous.append($count)
			$count = $count + 1
		}
		var $row_number = 0
		for x in a.to_utf8() {
			$row_number = $row_number + 1
			var $row = [$row_number]
			var $j = 0
			for y in right {
				deleted = ($previous.get($j + 1) ?? 0) + 1
				inserted = ($row.get($j) ?? 0) + 1
				replaced = ($previous.get($j) ?? 0) + (if (x == y) 0 else 1)
				$row = $row.append(deleted.min(inserted).min(replaced))
				$j = $j + 1
			}
			$previous = $row
		}
		$previous.last() ?? 0
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

	## A command's page, if `message` is one, listing its choices' summaries.
	listed = |config, commands, style, message| {
		page = |shown, name| WeaverHelp.help_text(shown, ["kai", name], style)
		shown = commands.find_first(|c| message == page(config, c.name))
		match (shown, config.subcommands) {
			(Ok(command), HasSubcommands({ commands: pages, required })) => {
				summarized_pages = pages.map(
					|(name, sub)|
						if name == command.name {
							(name, { ..sub, subcommands: Argv.summarized(sub) })
						} else {
							(name, sub)
						},
				)
				subcommands = HasSubcommands({ commands: summarized_pages, required })
				page({ ..config, subcommands }, command.name)
			}
			_ => message
		}
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
					# Help lists the summary, the paragraph before the details.
					about = Str.join_with([c.summary].concat(c.details), "\n\n")
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

# A missing name lists the choices, and an unknown command or name suggests
# the closest without running it.
expect
	parsed(["--backend", "guix", "run"])
		== Err(Usage("kai run needs a task; available tasks: args"))
		and parsed(["build"]) == Err(Usage("kai build needs a name"))
		and parsed(["rn", "args"])
			== Err(
				Usage(
					"no command named rn; available commands: shell, run, build, "
						.concat("update; did you mean `run`?"),
				),
			)
		and parsed(["shell", "dfault"])
			== Err(
				Usage(
					"no shell named dfault; available shells: default, ci; "
						.concat("did you mean `default`?"),
				),
			)

# The closest names are at most two edits away, and fewer than the word has.
expect [
	("rn", ["run", "shell", "build"], ["run"]),
	("moo2", ["moo", "say", "moon"], ["moo", "moon"]),
	("frobnicate", ["run", "shell"], []),
	("x", ["a", "b"], []),
	("bild", ["build", "build-all"], ["build"]),
].all(|(given, names, expected)| Argv.closest(given, names) == expected)
	and Argv.distance("kitten", "sitting") == 3

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

# A command's page lists each choice's summary; the choice's own page shows
# its details after it.
expect {
	run = Command.{
		name: "run",
		summary: "",
		help: page,
		args: [
			Name({
				name: "task",
				help: "",
				choices: [
					{ value: "moo", summary: "Says moo", details: ["cowsay moo [cow]"] },
				],
				default: Required,
			}),
			Trailing({ name: "args", help: "", choices: [] }),
		],
		lock: ReadsLock,
	}
	help_of = |argv|
		match Argv.parse(page, [run], Plain, "/work", argv) {
			Err(Help(text)) => text
			_ => ""
		}
	listing = help_of(["run", "--help"])
	own = help_of(["run", "moo", "--help"])
	listing.contains("  moo  Says moo\n")
		and !listing.contains("cowsay moo")
		and own.contains("Says moo\n\ncowsay moo [cow]")
}
