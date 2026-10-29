# Loops through examples/ to demonstrate every Kai feature.
#
# Setup in each example/<example> dir is:
# - example
#   | commands          input command args to kai e.g. `update`, `run` etc.
#   | Kaifile.roc       describes what to run given the above commands
#   | stdout            expected stdout given the run for validation
#   | project           optional: the subdirectory holding Kaifile.roc, in
#                       which the commands run, such as an app in a workspace
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stdout

import Exec

import E2e

E2eExamples := [].{

	## Settings no example can show: no std backend renders Custom data.
	unshown = ["Custom"]

	## Files an example keeps beside its project rather than in it.
	metadata = ["Kaifile.roc", "commands", "stdout", "project"]

	nix! = |binary| {
		root = Path.canonicalize!(Env.cwd!()?)?
		examples = Path.join(root, "examples")
		var $commands = []
		var $sources = []
		var $offered = []
		for name in E2eExamples.names!(examples)? {
			dir = Path.join(examples, name)
			lines = Path.read_utf8!(Path.join(dir, "commands"))?
				.split_on("\n")
				.keep_if(|line| !line.trim().is_empty())
			entries = Path.list!(dir)?
				.map(|path| Path.display(Path.filename(path) ?? path))
				.keep_if(|entry| !E2eExamples.metadata.contains(entry))
			kaifile_dir = E2eExamples.kaifile_dir!(dir)?
			(kai, copy) =
				E2e.nix_copy_tree!(binary, "examples/${name}", entries, kaifile_dir)?
			(source, project) = E2e.kaifile_dirs(dir, copy, kaifile_dir)
			result = E2eExamples.run_in!(kai, project, name, lines)
			match result {
				Ok(_) if $offered.is_empty() => {
					$offered = E2eExamples.offered!(kai, project)?
				}
				_ => {}
			}
			Path.delete_all!(copy)?
			stdout = result?
			expected = Path.join(dir, "stdout")
			if Path.exists!(expected)? and Path.read_utf8!(expected)? != stdout {
				return Err(WrongExampleOutput({ example: name, stdout }))
			}
			$commands = $commands.concat(lines.map(E2eExamples.command_name))
			for file in Path.list!(source)? {
				if Path.display(file).ends_with(".roc") {
					$sources = $sources.append(Path.read_utf8!(file)?)
				}
			}
			Stdout.line!("example ${name} ran")?
		}
		config = Path.read_utf8!(Path.join(root, "plugins/std/Config.roc"))?
		missing = E2eExamples.missing(
			$offered,
			$commands,
			E2eExamples.settings(config),
			$sources,
		)
		if !missing.is_empty() {
			return Err(FeaturesWithoutExamples(missing))
		}
		Stdout.line!("every std command and Kaifile setting has an example")
	}

	## Example directories: those holding a commands file and a Kaifile.roc,
	## or a project file naming the subdirectory that holds it.
	names! = |examples| {
		var $names = []
		for dir in Path.list!(examples)? {
			name = Path.display(Path.filename(dir) ?? dir)
			if
				Path.is_dir!(dir)?
					and Path.is_file!(Path.join(dir, "commands"))?
					and (Path.is_file!(Path.join(dir, "Kaifile.roc"))?
						or Path.is_file!(Path.join(dir, "project"))?)
					{
						$names = $names.append(name)
					}
		}
		Ok($names)
	}

	## The subdirectory an example's project file names, empty without one.
	kaifile_dir! = |dir| {
		project = Path.join(dir, "project")
		if Path.is_file!(project)? {
			Ok(Path.read_utf8!(project)?.trim())
		} else {
			Ok("")
		}
	}

	## Run each command in order and return their stdout, apart from update's
	## report. `update` locks only Nix, so a host with Guix too never waits for
	## a Guix lock.
	run_in! = |kai, project, name, lines| {
		var $stdout = ""
		for line in lines {
			args = line.split_on(" ").keep_if(|arg| !arg.is_empty())
			argv = if (args == ["update"]) ["--backend", "nix", "update"] else args
			command = Cmd.new(Path.to_os_str(kai)).args(Exec.strs(argv)).cwd(project)
			output = match Exec.output!(command) {
				Ok(ran) => ran
				Err(failure) =>
					return Err(ExampleCommandFailed({ example: name, command: line, failure }))
			}
			if args != ["update"] {
				$stdout = $stdout.concat(output.stdout_utf8)
			}
		}
		Ok($stdout)
	}

	## The commands the Kaifile's plugins offer, from `kai describe`.
	offered! = |kai, project| {
		described = Exec.output!(
			Cmd.new(Path.to_os_str(kai)).args(Exec.strs(["describe"]))
				.cwd(project),
		)?
		Ok(E2eExamples.described_commands(described.stdout_utf8))
	}

	described_commands : Str -> List(Str)
	described_commands = |text| {
		for line in text.split_on("\n") {
			if line.starts_with("commands: ") {
				return line.drop_prefix("commands: ").split_on(", ")
			}
		}
		[]
	}

	## A command line's command: its first word that is not a flag.
	command_name : Str -> Str
	command_name = |line|
		line.split_on(" ")
			.find_first(|word| !word.is_empty() and !word.starts_with("-"))
			?? ""

	## The tags of every bracketed type in Config.roc, such as `Name`, `Auto`
	## and `Use`, each with whether it takes a payload.
	settings : Str -> List(Tag)
	settings = |config| {
		var $tags = []
		var $inside = Bool.False
		for line in config.split_on("\n") {
			trimmed = line.trim()
			elements =
				if $inside {
					if trimmed.starts_with("]") {
						$inside = Bool.False
						[]
					} else {
						[trimmed.drop_suffix(",")]
					}
				} else if trimmed.ends_with(": [") {
					$inside = Bool.True
					[]
				} else {
					match trimmed.split_on(": [") {
						[_, rest] => E2eExamples.top_level(rest.drop_suffix("]"))
						_ => []
					}
				}
			for element in elements {
				tag = element.split_on("(").first() ?? ""
				if !tag.is_empty() and !$tags.any(|t| t.tag == tag) {
					$tags = $tags.append({ tag, payload: element.contains("(") })
				}
			}
		}
		$tags
	}

	## The comma-separated elements of a one-line union, keeping a payload such
	## as `Env(List((Str, Str)))` whole.
	top_level : Str -> List(Str)
	top_level = |text| {
		var $parts = []
		var $current = ""
		for piece in text.split_on(", ") {
			$current = if ($current.is_empty()) piece else "${$current}, ${piece}"
			bytes = $current.to_utf8()
			if bytes.count_if(|b| b == '(') == bytes.count_if(|b| b == ')') {
				$parts = $parts.append($current)
				$current = ""
			}
		}
		$parts
	}

	## What no example shows: offered commands no commands file runs, and
	## settings no example's Roc source uses, apart from `unshown`.
	Tag : { tag : Str, payload : Bool }

	missing : List(Str), List(Str), List(Tag), List(Str) -> List(Str)
	missing = |offered, commands, tags, sources| {
		uses = |tag|
			sources.any(
				|source|
					if tag.payload {
						source.contains("${tag.tag}(")
					} else {
						source.contains(tag.tag)
					},
			)
		unrun = offered.keep_if(|command| !commands.contains(command))
			.map(|command| "command ${command}")
		unused = tags.keep_if(
			|tag| !E2eExamples.unshown.contains(tag.tag) and !uses(tag),
		)
			.map(|tag| "setting ${tag.tag}")
		unrun.concat(unused)
	}
}

# The commands line `kai describe` prints lists the offered commands.
expect
	E2eExamples.described_commands("plugins: std\ncommands: shell, run\n")
		== ["shell", "run"]

# A command line's command skips leading flags.
expect
	["update", "--json workflow ci", "shell default -- cowsay moo"]
		.map(E2eExamples.command_name)
		== ["update", "workflow", "shell"]

# Tags come from one-line and multi-line bracketed types.
expect
	E2eExamples.settings(
		\\	Setting : [
		\\		Name(Str),
		\\		Raw(Str, Str, Val),
		\\	]
		\\	PackageSource : [Auto, From(Provider)]
		\\	ShellSetting : [Use(EnvName)]
	)
		== [
			{ tag: "Name", payload: Bool.True },
			{ tag: "Raw", payload: Bool.True },
			{ tag: "Auto", payload: Bool.False },
			{ tag: "From", payload: Bool.True },
			{ tag: "Use", payload: Bool.True },
		]

# Unrun commands and unused settings are missing; Custom never is.
expect
	E2eExamples.missing(
		["shell", "build"],
		["shell"],
		[
			{ tag: "Name", payload: Bool.True },
			{ tag: "Auto", payload: Bool.False },
			{ tag: "Custom", payload: Bool.True },
		],
		["Name(\"x\")"],
	)
		== ["command build", "setting Auto"]

# A one-line union keeps a payload with a tuple type whole.
expect
	E2eExamples.top_level("Use(EnvName), Env(List((Str, Str))), Run(List(Str))")
		== ["Use(EnvName)", "Env(List((Str, Str)))", "Run(List(Str))"]
