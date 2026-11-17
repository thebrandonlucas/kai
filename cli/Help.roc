# kai's own help: the header a Kaifile.roc starts with, and what kai says
# when there is no Kaifile.roc to ask. Command help comes from the Kaifile's
# plugins.
import "../platform-release" as platform_release : Str
import "../plugins/std-release" as std_release : Str
import api.About

import Variables

Help := [].{
	examples = "https://github.com/thebrandonlucas/kai/tree/master/examples"

	# How a Kaifile.roc starts, with the platform and std bundles this Kai's
	# release publishes, in full so they can be copied; `settings` is the
	# list given to std.
	header : Str -> Str
	header = |settings|
		\\  app [kaifile] {
		\\      pf: platform "${platform_release.trim()}",
		\\      std: "${std_release.trim()}",
		\\  }
		\\
		\\  import std.Std
		\\
		\\  kaifile = Std.kaifile(${settings})

	# The last lines of every help page kai prints itself.
	tips =
		\\Put arguments for a shell command or task after --.
		\\Set KAI_ROC to choose the Roc compiler (default: roc).

	# What kai's own help ends with, in a project or not.
	notes =
		\\Kaifile.roc starts with:
		\\${Help.header("[...]")}
		\\
		\\${Help.tips}

	# The Kaifile.roc `kai init` writes for project `name`: this release's
	# platform and std, in full, the Linux and Apple Silicon macOS systems, and
	# a shell and task with cowsay and fortune.
	kaifile : Str -> Str
	kaifile = |name| {
		quoted = name
			.replace_each("\\", "\\\\")
			.replace_each("\"", "\\\"")
			.replace_each("$", "\\$")
		Help.kaifile_named(quoted)
	}

	kaifile_named : Str -> Str
	kaifile_named = |name|
		\\# This project's Kai configuration. Every setting has an example in
		\\# ${Help.examples}
		\\app [kaifile] {
		\\	pf: platform "${platform_release.trim()}",
		\\	std: "${std_release.trim()}",
		\\}
		\\
		\\import std.Std
		\\
		\\kaifile = Std.kaifile([
		\\	Name("${name}"),
		\\	Systems(["x86_64-linux", "aarch64-linux", "aarch64-darwin"]),
		\\	Environment("cow", [Tools(["cowsay", "fortune"])]),
		\\	Shell("default", [Use("cow")]),
		\\	Task("wisdom", [Use("cow"), Run(["sh", "-c", "fortune | cowsay"])]),
		\\])
		\\

	# What to do after `kai init`, or instead of a missing Kaifile.roc.
	next_steps =
		\\Then run `kai update` to pin its packages, then `kai run wisdom` for a
		\\wise cow, or `kai shell` to enter its environment. Every setting has an
		\\example in:
		\\  ${Help.examples}

	# Why kai's own help is shown when there is no Kaifile.roc, and how to
	# start one.
	starter =
		\\There is no Kaifile.roc here. Run `kai init` to create a starter one, with
		\\a shell containing cowsay and fortune and a task that runs them.
		\\${Help.next_steps}

	# The Kaifile cannot know kai's version, so kai adds it to the title.
	versioned : Str, Str -> Str
	versioned = |text, version|
		match text.split_first("\n") {
			Ok({ before, after }) => "${before} ${version}\n${after}"
			Err(_) => text
		}

	# One aligned line for each environment variable kai reads.
	environment : Str
	environment = Str.join_with(
		Variables.all.map(
			|{ name, description }| {
				width = 21 - name.count_utf8_bytes()
				padding = Str.from_utf8(List.repeat(' ', width)) ?? ""
				"  ${name}${padding}${description}"
			},
		),
		"\n",
	)

	# Shown when Kaifile.roc is missing or does not compile, since its
	# plugins define the rest of the commands.
	generic : Str, Str -> Str
	generic = |version, why|
		\\kai ${version}
		\\
		\\${About.text}
		\\
		\\${why}
		\\
		\\Usage:
		\\  kai [OPTIONS] <COMMAND>
		\\
		\\Commands:
		\\  init           Create a Kaifile.roc here to start a project.
		\\  check          Compile Kaifile.roc and report whether it is valid.
		\\  describe       List Kaifile.roc's plugins, commands and backends.
		\\  bundle-plugin  Bundle a plugin package for this kai's release.
		\\
		\\A Kaifile.roc's plugins add the other commands: std adds shell, run, build,
		\\workflow, update and model.
		\\
		\\Options:
		\\  -f STR, --file STR  Read PATH (default: nearest Kaifile.roc in the repo).
		\\  --no-color          Print plain text without colors.
		\\  --json              Print kai's own output as JSON Lines.
		\\  --backend STR       Use this backend instead of choosing automatically.
		\\  --yes               Answer yes to every confirmation.
		\\  --dry-run           Print the plan instead of running it.
		\\  -h, --help          Show this help page.
		\\  -V, --version       Show the version.
		\\
		\\Environment:
		\\${Help.environment}
		\\
		\\${Help.notes}

	# What `kai` alone prints at a terminal: what kai is and its common
	# commands, the same in a project or not.
	concise : Str -> Str
	concise = |version|
		\\kai ${version}: ${About.tagline}
		\\
		\\Usage:
		\\  kai [OPTIONS] <COMMAND>
		\\
		\\Common commands:
		\\  init            Create a Kaifile.roc here to start a project.
		\\  update          Pin the packages Kaifile.roc uses.
		\\  shell [<NAME>]  Enter a shell, or run a command in it after --.
		\\  run <TASK>      Run a task; arguments after -- are the task's.
		\\  build <NAME>    Build an artifact and print its store path.
		\\
		\\Run `kai --help` for every command and option.

	# Without a command, and not at a terminal, `kai` is a usage error.
	needs_command = "kai needs a command; run `kai --help` to list them"

	# `kai bundle-plugin`'s help, also its usage error.
	bundle_plugin =
		\\Usage:
		\\  kai bundle-plugin [DIR] [--output-dir DIR] [--platform URL] [--std URL]
		\\
		\\Bundle the plugin package in DIR (default: the current directory) with
		\\`roc bundle`, its header naming this kai's platform and std releases, into
		\\<hash>.tar.zst in --output-dir (default: DIR). Host it, and a Kaifile.roc
		\\using that platform and std can name it by its URL. --platform and --std
		\\name other hosted platform and std bundles instead, such as a newer
		\\release's.

	# Color is decoration only: NO_COLOR (when non-empty), --no-color or output
	# that is not a terminal all get plain text.
	text_style : { terminal : Bool, no_color : Str, flag : Bool } -> [Color, Plain]
	text_style = |{ terminal, no_color, flag }|
		if (terminal and no_color.is_empty() and !flag) Color else Plain
}

# Only an interactive terminal without an opt-out gets color.
expect [
	({ terminal: Bool.True, no_color: "", flag: Bool.False }, Color),
	({ terminal: Bool.False, no_color: "", flag: Bool.False }, Plain),
	({ terminal: Bool.True, no_color: "1", flag: Bool.False }, Plain),
	({ terminal: Bool.True, no_color: "", flag: Bool.True }, Plain),
	({ terminal: Bool.False, no_color: "1", flag: Bool.True }, Plain),
].all(|(input, expected)| Help.text_style(input) == expected)

# Help names this release's platform and std in full, as kai init writes
# them, outside a project too.
expect {
	full = "pf: platform \"${platform_release.trim()}\","
	Help.generic("0", "").contains(full) and Help.kaifile("x").contains(full)
}

# A project name is quoted as a Roc string, whatever its directory is called.
expect Help.kaifile("a\"b\\c$d").contains("Name(\"a\\\"b\\\\c\\$d\"),")

# Help names KAI_ROC as kai's compiler and ROC only as its deprecated name.
expect {
	lines = Help.environment.split_on("\n")
	named = |name, text|
		lines.any(|line| line.starts_with("  ${name} ") and line.contains(text))
	named("KAI_ROC", "Kaifile.roc") and named("ROC", "Deprecated")
}
