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
		evaluate = ["eval", "--raw", "--impure", "--expr", "builtins.currentSystem"]
		host = Exec.output!(Exec.cmd("nix").args(Exec.strs(evaluate)))?
			.stdout_utf8
			.trim()
		names = E2eExamples.names!(examples)?
		# Every example counts towards the check below, though a shard runs some.
		for name in names {
			dir = Path.join(examples, name)
			lines = E2eExamples.commands!(dir, host)?
			$commands = $commands.concat(lines.map(E2eExamples.command_name))
			(source, _) = E2e.kaifile_dirs(dir, dir, E2eExamples.kaifile_dir!(dir)?)
			for file in Path.list!(source)? {
				if Path.display(file).ends_with(".roc") {
					$sources = $sources.append(Path.read_utf8!(file)?)
				}
			}
		}
		for name in E2eExamples.shard(names, Env.var_str!("KAI_E2E_SHARD") ?? "")? {
			dir = Path.join(examples, name)
			lines = E2eExamples.commands!(dir, host)?
			entries = Path.list!(dir)?
				.map(|path| Path.display(Path.filename(path) ?? path))
				.keep_if(|entry| !E2eExamples.metadata.contains(entry))
			kaifile_dir = E2eExamples.kaifile_dir!(dir)?
			(kai, copy) =
				E2e.nix_copy_tree!(binary, "examples/${name}", entries, kaifile_dir)?
			(_, project) = E2e.kaifile_dirs(dir, copy, kaifile_dir)
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

	## The command lines an example's commands file holds that run on `host`.
	commands! = |dir, host|
		Ok(
			Path.read_utf8!(Path.join(dir, "commands"))?
				.split_on("\n")
				.keep_if(|line| !line.trim().is_empty())
				.keep_oks(|line| E2eExamples.on_host(line, host)),
		)

	## The examples to run: all, or for a shard `i/n` (KAI_E2E_SHARD), every
	## n-th in byte order from the i-th, so CI can split them across jobs.
	shard : List(Str), Str -> Try(List(Str), [BadShard(Str)])
	shard = |names, spec| {
		if spec.is_empty() {
			return Ok(names)
		}
		(index, count) = match spec.split_on("/").map(U64.from_str) {
			[Ok(i), Ok(n)] if i >= 1 and i <= n => (i, n)
			_ => return Err(BadShard(spec))
		}
		var $kept = []
		var $position = 0
		for name in names.sort_with(E2eExamples.byte_order) {
			if $position % count == index - 1 {
				$kept = $kept.append(name)
			}
			$position = $position + 1
		}
		Ok($kept)
	}

	## Byte order of two names, for sorting.
	byte_order : Str, Str -> [Before, Same, After]
	byte_order = |left, right| {
		(a, b) = (left.to_utf8(), right.to_utf8())
		var $index = 0
		while $index < a.len() and $index < b.len() {
			(x, y) = (a.get($index) ?? 0, b.get($index) ?? 0)
			if x != y {
				return if (x < y) Before else After
			}
			$index = $index + 1
		}
		a.len().order_relative_to(b.len())
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
	## a Guix lock, except in the direct, downloads, mixed and roc-packages
	## examples, whose downloads direct pins.
	run_in! = |kai, project, name, lines| {
		pinned_by_direct = ["direct", "downloads", "mixed", "roc-packages"]
		var $stdout = ""
		for line in lines {
			args = line.split_on(" ").keep_if(|arg| !arg.is_empty())
			argv =
				if args == ["update"] and !pinned_by_direct.contains(name) {
					["--backend", "nix", "update"]
				} else {
					args
				}
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

	## A commands line `<system>: <command>` runs only on a host of that
	## system, such as a NixOS machine's build; any other line runs anywhere.
	on_host : Str, Str -> Try(Str, [OtherHost])
	on_host = |line, host|
		match line.split_first(": ") {
			Ok({ before, after }) if !before.contains(" ") =>
				if (before == host) Ok(after) else Err(OtherHost)
			_ => Ok(line)
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

# A shard runs every n-th example in byte order.
expect E2eExamples.shard(["c", "a", "b"], "2/2") == Ok(["b"])

# A shorter name sorts before a longer one it begins.
expect E2eExamples.shard(["c", "ab", "a"], "1/2") == Ok(["a", "c"])

# With no shard, every example runs.
expect E2eExamples.shard(["b", "a"], "") == Ok(["b", "a"])

# A shard past the count is refused.
expect E2eExamples.shard(["a"], "3/2") == Err(BadShard("3/2"))

# A line naming a system runs only on that host, without its prefix.
expect {
	lines = ["update", "x86_64-linux: machine build web", "run say -- a: b"]
	on = |host| lines.keep_oks(|line| E2eExamples.on_host(line, host))
	on("x86_64-linux") == ["update", "machine build web", "run say -- a: b"]
		and on("aarch64-linux") == ["update", "run say -- a: b"]
}
