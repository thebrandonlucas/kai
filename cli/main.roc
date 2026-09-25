# kai: developer environments, tasks and builds from a Kaifile.roc.
#
# Transitional entry point for the native Roc Kaifile; it replaces the xkai
# CLI once it covers the supported commands.
app [main!] {
	pf: platform "../.basic-cli/main.roc",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/${
		""
	}0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	ir: "../kaifile/ir/main.roc",
	nix: "../kaifile/nix/main.roc",
	guix: "../kaifile/guix/main.roc",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Stderr
import pf.Stdout
import weaver.Cli
import weaver.Help as WeaverHelp
import weaver.Opt
import weaver.Param
import weaver.SubCmd
import ir.Ir
import ir.Request

import Execute
import Help
import Load
import Selection
import Update
import Workspace

version = "0.0.7"

Command : [
	Check,
	PrintIr,
	UpdateLock,
	Shell(Str, List(Str)),
	Run(Str, List(Str)),
]

description = Help.describe(Help.kai).concat(
	\\
	\\
	\\Set ROC to choose the Roc compiler (default: roc).
	\\Put arguments for a shell command or task after --.
	,
)

Parsed : {
	file : Try(Str, [NoValue]),
	no_color : Bool,
	backend : Try(Str, [NoValue]),
	command : Command,
}

# When Kaifile.roc loads, its shells and tasks become subcommands so help and
# usage errors list what the project defines. Otherwise, or when a name is not
# a valid subcommand, the parsers are generic and the help says why.
parser : Try(Ir, _), [Color, Plain] -> Cli.CliParser(Parsed)
parser = |loaded, text_style| {
	generic = |note|
		Cli.assert_valid(
			cli(generic_shell, generic_run, note, text_style),
		)
	match loaded {
		Ok(ir) => {
			shell = if ir.shells.is_empty() generic_shell else project_shell(ir)
			run = if ir.tasks.is_empty() generic_run else project_run(ir)
			cli(shell, run, "", text_style) ?? generic(
				"Kaifile.roc names are not all valid subcommands, so they "
					.concat("aren't listed."),
			)
		}
		Err(NoKaifile(_)) => generic("There is no Kaifile.roc here.")
		Err(_) => generic(
			"Kaifile.roc could not be loaded, so its shells and tasks aren't "
				.concat("listed; run `kai check` for details."),
		)
	}
}

cli = |shell, run, note, text_style|
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
			backend: Opt.maybe_str({
				short: "",
				long: "backend",
				help: "Use nix or guix instead of choosing automatically.",
			}),
			command: SubCmd.required([
				shell,
				run,
				SubCmd.empty({
					name: "check",
					description: Help.describe(Help.check),
					value: Check,
				}),
				SubCmd.empty({
					name: "ir",
					description: Help.describe(Help.ir),
					value: PrintIr,
				}),
				SubCmd.empty({
					name: "update",
					description: Help.describe(Help.update),
					value: UpdateLock,
				}),
			]),
		}.Cli,
		{
			name: "kai",
			version,
			authors: [],
			description: if note.is_empty() {
				description
			} else {
				"${description}\n\n${note}"
			},
			text_style,
		},
	)

shell_description = Help.describe(Help.shell)

run_description = Help.describe(Help.run)

command_param = Param.str_list({
	name: "command",
	help: "A command to run inside the shell; put it after --.",
})

args_param = Param.str_list({
	name: "args",
	help: "Arguments appended to the task's command; put them after --.",
})

generic_shell = SubCmd.finish(
	{
		name: Param.maybe_str({
			name: "name",
			help: "The shell to enter (default: default).",
		}),
		command: command_param,
	}.Cli,
	{
		name: "shell",
		description: shell_description,
		mapper: |{ name, command }| Shell(name ?? "default", command),
	},
)

generic_run = SubCmd.finish(
	{
		task: Param.str({
			name: "task",
			help: "The task to run.",
			default: NoDefault,
		}),
		args: args_param,
	}.Cli,
	{
		name: "run",
		description: run_description,
		mapper: |{ task, args }| Run(task, args),
	},
)

project_shell = |ir|
	SubCmd.finish(
		Cli.map(
			SubCmd.optional(
				ir.shells.map(
					|shell|
						SubCmd.finish(
							command_param,
							{
								name: shell.name,
								description: "Environment ${shell.environment}",
								mapper: |command| Shell(shell.name, command),
							},
						),
				),
			),
			|picked| picked ?? Shell("default", []),
		),
		{
			name: "shell",
			description: shell_description,
			mapper: |c| c,
		},
	)

project_run = |ir|
	SubCmd.finish(
		SubCmd.required(
			ir.tasks.map(
				|task|
					SubCmd.finish(
						args_param,
						{
							name: task.name,
							description: Str.join_with(task.run, " ")
								.concat(" [${task.environment}]"),
							mapper: |args| Run(task.name, args),
						},
					),
			),
		),
		{ name: "run", description: run_description, mapper: |c| c },
	)

# Help depends on the configuration, so --file is found before parsing, the
# way the parser reads it. Arguments after -- belong to a task or command.
requested_file : List(Str) -> Try(Str, [NoValue])
requested_file = |args|
	match args {
		[] | ["--", ..] => Err(NoValue)
		["-f", value, ..] | ["--file", value, ..] => Ok(value)
		[arg, .. as rest] =>
			if arg.starts_with("--file=") {
				Ok(arg.drop_prefix("--file="))
			} else {
				requested_file(rest)
			}
		}

# --no-color decides how help renders, so it is also found before parsing.
requests_no_color : List(Str) -> Bool
requests_no_color = |args|
	match args {
		[] | ["--", ..] => Bool.False
		["--no-color", ..] => Bool.True
		[_, .. as rest] => requests_no_color(rest)
	}

# Kai's help lists each command's summary; a command's own help teaches it.
display : Cli.CliParser(Parsed), List(arg), (arg -> _) -> Try(Parsed, _)
display = |kai, args, to_raw| {
	parsed = Cli.parse_or_display_message(kai, args, to_raw)
	root = |config| WeaverHelp.help_text(config, ["kai"], kai.text_style)
	match parsed {
		Err(Help(message)) =>
			if message == root(kai.config) {
				summary = { ..kai.config, subcommands: summarized(kai.config) }
				Err(Help(root(summary)))
			} else {
				parsed
			}
		_ => parsed
	}
}

summarized = |config|
	match config.subcommands {
		HasSubcommands({ commands, required }) =>
			HasSubcommands({
				commands: commands.map(
					|(name, command)|
						(name, { ..command, description: Help.summary(command.description) }),
				),
				required,
			})
		NoSubcommands => NoSubcommands
	}

is_terminal! = |descriptor|
	match Cmd.new_str("test").args_str(["-t", descriptor]).exec_exit_code!() {
		Ok(0) => Bool.True
		_ => Bool.False
	}

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	text_style = Help.text_style({
		terminal: is_terminal!("1") and is_terminal!("2"),
		no_color: Env.var_str!("NO_COLOR") ?? "",
		flag: requests_no_color(args.map(OsStr.display)),
	})
	located = Load.project!(requested_file(args.map(OsStr.display)))
	loaded = match located {
		Ok(project) => Load.ir!(project)
		Err(err) => Err(err)
	}
	parsed = display(parser(loaded, text_style), args, OsStr.to_raw)
	match parsed {
		Err(Help(message)) | Err(Version(message)) =>
			Stdout.line!(message).map_err(|_| Exit(1))
		Err(InvalidUsage(message)) => {
			_ = Stderr.line!(message)
			Err(Exit(2))
		}
		Ok({ command, backend, .. }) =>
			match run!(command, backend, located, loaded) {
				Ok({}) => Ok({})
				Err(err) => {
					_ = Stderr.line!("kai: ${describe(err)}")
					Err(Exit(exit_status(err)))
				}
			}
		}
}

run! = |command, backend, located, loaded| {
	choice = backend_choice(backend)?
	project = located?
	match command {
		Check => {
			Load.check!(project)?
			_ = loaded?
			Stdout.line!("${project.file} is valid")
		}
		PrintIr => Stdout.write!(loaded?.to_str())
		UpdateLock => {
			ir = loaded?
			Selection.lockable(choice, ir)?
			layout = Workspace.locate!(project.root)?
			Update.update!(ir, layout)?
			Stdout.line!("updated ${layout.lock_path}")
		}
		Shell(name, shell_command) =>
			Execute.select!(
				loaded?,
				Request.Shell(name, shell_command),
				choice,
				project.root,
			)
		Run(task, args) =>
			Execute.select!(loaded?, Request.Run(task, args), choice, project.root)
		}
}

# --backend narrows automatic selection to one backend; commands that do not
# run a backend still reject an unknown name.
backend_choice : Try(Str, [NoValue]) -> Try(Selection.BackendChoice, _)
backend_choice = |value|
	match value {
		Err(NoValue) => Ok(Auto)
		Ok("nix") => Ok(Only(Nix))
		Ok("guix") => Ok(Only(Guix))
		Ok(other) => Err(InvalidBackend(other))
	}

exit_status = |err|
	match err {
		ChildExited(_, code) => Execute.exit_code(code)
		InvalidBackend(_) => 2
		_ => 1
	}

describe : _ -> Str
describe = |err|
	match err {
		NoKaifile(location) => "no Kaifile.roc at ${location}"
		UnsupportedHost =>
			"evaluating Kaifile.roc currently requires an x86_64 Linux host"
		CompilerUnavailable(compiler, message) =>
			"could not run the Roc compiler `${compiler}`; install the pinned "
				.concat("compiler or set ROC to it:\n${message}")
		CompilerMismatch(compiler, actual) =>
			"`${compiler}` is ${actual}; Kai needs the pinned Roc compiler"
		KaifileInvalid(file) => "${file} did not compile; see the errors above"
		KaifileFailed(file, output) => "${file} did not compile:\n${output}"
		BadIr(UnsupportedFormat({ major, minor })) =>
			"Kaifile IR ${U64.to_str(major)}.${U64.to_str(minor)} is not supported; "
				.concat("this kai reads major ${Ir.current_format.major.to_str()}")
		BadIr(reason) => "could not read the Kaifile IR: ${Str.inspect(reason)}"
		NeedsFeatures(missing) =>
			"Kaifile.roc needs unsupported features: "
				.concat(Str.join_with(missing, ", "))
		InvalidProject(message) => "invalid Kaifile: ${message}"
		InvalidWorkspace(message) => "invalid workspace: ${message}"
		UnsafeWorkspace(message) => "unsafe workspace: ${message}"
		UnsafePath(value) => "refusing unsafe or symlinked path: ${value}"
		RenderFailed(message) => "cannot generate the Nix files: ${message}"
		LockFailed(message) => "cannot lock the Nix inputs: ${message}"
		NoLock(path) => "no lock file at ${path}; run `kai update`"
		BadLock(path, message) =>
			"cannot read the lock file ${path}: ${message}; run `kai update`"
		LocalChanged(path) => "local source ${path} changed; run `kai update`"
		Unsupported(what) => "kai cannot execute a ${what} yet"
		ChildExited(Shell(name), code) =>
			"shell ${name} exited with code ${code.to_str()}"
		ChildExited(Run(name), code) =>
			"task ${name} exited with code ${code.to_str()}"
		ChildExited(_, code) => "command exited with code ${code.to_str()}"
		ExecCmdFailed({ command, exit_code }) =>
			"`${command}` exited with code ${exit_code.to_str()}"
		UpdateLocked(guard) =>
			"another kai update holds ${guard}; if none is running, it is "
				.concat("safe to remove that directory")
		AuthorityChanged => "the lock file changed during update; retry kai update"
		InvalidBackend(value) => "--backend must be nix or guix, not '${value}'"
		BackendConflict(backend, why) =>
			"--backend ${Selection.name(backend)} cannot serve this request: ${why}"
		NoEligibleBackend(reasons) =>
			"no backend can serve this request:\n  "
				.concat(Str.join_with(reasons.keep_if(|r| !r.is_empty()), "\n  "))
		RequiredBackendUnavailable(backend, probe) =>
			"this request needs ${Selection.name(backend)}, which "
				.concat(Selection.probe_text(probe))
		GuixLockUnsupported =>
			"locking is not supported for Guix sources; Guix shells use the "
				.concat("installed Guix channels")
		GuixFailed(message) => "cannot plan the Guix shell: ${message}"
		other => Str.inspect(other)
	}

test_ir = Ir.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (shells (((name "default") (environment "dev"))
	\\  ((name "ci") (environment "dev"))))
	\\ (tasks (((name "args") (environment "dev") (run ("echo"))))))
	,
)

render = |loaded, args, style| display(parser(loaded, style), args, |a| Utf8(a))

parse = |loaded, args| render(loaded, args, Plain)

parses = |loaded, args, expected|
	match parse(loaded, args) {
		Ok({ command, .. }) => command == expected
		_ => Bool.False
	}

# Arguments after -- reach the task or shell command exactly, never kai.
expect [
	(["run", "args", "--", "--json", "--yes"], Run("args", ["--json", "--yes"])),
	(
		["run", "args", "--", "first", "two words", "--literal", ""],
		Run("args", ["first", "two words", "--literal", ""]),
	),
	(["run", "args", "--", "--", "-f", "x"], Run("args", ["--", "-f", "x"])),
	(["shell"], Shell("default", [])),
	(["shell", "ci"], Shell("ci", [])),
	(
		["shell", "ci", "--", "git", "--version"],
		Shell("ci", ["git", "--version"]),
	),
	(["-f", "Kaifile.roc", "run", "args"], Run("args", [])),
	(
		["--no-color", "run", "args", "--", "--no-color"],
		Run("args", ["--no-color"]),
	),
	(
		["--backend", "guix", "shell", "ci", "--", "--backend", "nix"],
		Shell("ci", ["--backend", "nix"]),
	),
].all(|(args, expected)| parses(test_ir, args, expected))

# Without a configuration the generic parsers accept any name.
expect [
	(["run", "test", "--", "--json", "--yes"], Run("test", ["--json", "--yes"])),
	(["shell", "dev", "--", "git"], Shell("dev", ["git"])),
	(["shell"], Shell("default", [])),
].all(|(args, expected)| parses(Err(NoKaifile("/x")), args, expected))

# Project-aware parsing rejects names the configuration does not define.
expect [["run", "missing"], ["shell", "missing"], ["run"]].all(
	|args|
		match parse(test_ir, args) {
			Err(InvalidUsage(_)) => Bool.True
			_ => Bool.False
		},
)

# Version and help never depend on loading the configuration.
expect [test_ir, Err(NoKaifile("/x")), Err(CompilerUnavailable("roc", ""))]
	.all(
		|loaded|
			match (parse(loaded, ["--version"]), parse(loaded, ["--help"])) {
				(Err(Version(v)), Err(Help(_))) => v == version
				_ => Bool.False
			},
	)

# Names that are not valid subcommands fall back to the generic parsers.
expect {
	dotted = Ir.parse(
		\\((format ((major 2) (minor 2))) (name "x")
		\\ (tasks (((name "check.unit") (environment "dev") (run ("true"))))))
		,
	)
	parses(dotted, ["run", "check.unit"], Run("check.unit", []))
}

# --file is found where the parser reads it, and never after --.
expect [
	(["-f", "a.roc", "check"], Ok("a.roc")),
	(["check", "--file", "b.roc"], Ok("b.roc")),
	(["--file=c.roc", "check"], Ok("c.roc")),
	(["run", "t", "--", "-f", "d.roc"], Err(NoValue)),
	(["check"], Err(NoValue)),
].all(|(args, expected)| requested_file(args) == expected)

# --no-color is kai's only before --; after it, the flag is the task's.
expect requests_no_color(["run", "t", "--no-color"])
	and !requests_no_color(["run", "t", "--", "--no-color"])

# --backend names one backend; anything else is a usage error.
expect [
	(Err(NoValue), Ok(Auto)),
	(Ok("nix"), Ok(Only(Nix))),
	(Ok("guix"), Ok(Only(Guix))),
	(Ok("Guix"), Err(InvalidBackend("Guix"))),
].all(|(value, expected)| backend_choice(value) == expected)

# A failing child's status becomes kai's, a bad --backend is a usage
# error, and every other failure is 1.
expect exit_status(ChildExited(Run("fail"), 7)) == 7
	and exit_status(InvalidBackend("x")) == 2
		and exit_status(NoLock("/p/.kai/lock.json")) == 1

help_text = |loaded, args, style|
	match render(loaded, args, style) {
		Err(Help(message)) => message
		_ => ""
	}

# Plain help says what a command accomplishes before Usage, then commands to
# try and the Kaifile.roc settings that enable them, with no ANSI escapes.
expect [test_ir, Err(NoKaifile("/x"))].all(
	|loaded|
		[
			([], Help.kai),
			(["check"], Help.check),
			(["ir"], Help.ir),
			(["update"], Help.update),
			(["shell"], Help.shell),
			(["run"], Help.run),
		].all(
			|(path, page)| {
				text = help_text(loaded, path.append("--help"), Plain)
				intro = Str.join_with(text.split_on("\n"), " ")
					.split_on("Usage:")
					.first() ?? ""
				[page.summary].concat(page.examples).concat(page.config)
					.all(|line| intro.contains(line))
					and text.split_on("Examples:").len() == 2
						and !text.contains("\u(001b)")
			},
		),
)

# Color only styles; the words are the same as in plain help.
expect {
	colored = help_text(test_ir, ["shell", "--help"], Color)
	colored.contains("\u(001b)")
		and colored.contains("kai shell dev -- git --version")
}
