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
					Err(Help(top({ ..config, subcommands: Argv.summarized(config) })))
				} else {
					Err(Help(message))
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
				description: Argv.describe(root),
				text_style: style,
			},
		)

	## A page as Weaver shows it. Weaver drops leading spaces, so headings
	## rather than indentation mark the sections; a parent shows only the
	## first paragraph.
	describe : Command.Page -> Str
	describe = |page| {
		section = |heading, lines|
			if lines.is_empty() [] else [Str.join_with([heading].concat(lines), "\n")]
		Str.join_with(
			[page.description]
				.concat(section("Examples:", page.examples))
				.concat(section("Kaifile.roc (inside Std.kaifile):", page.config)),
			"\n\n",
		)
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
		description = Argv.describe(command.help)
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
