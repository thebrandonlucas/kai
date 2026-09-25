# kai: developer environments, tasks and builds from a Kaifile.roc.
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
import Output
import Selection
import Update
import Workspace

import "../VERSION" as canonical_version : Str

version = canonical_version.trim()

Command : [
	Check,
	PrintIr,
	UpdateLock,
	Shell(Str, List(Str)),
	Run(Str, List(Str)),
	Build(Str),
	Workflow(Str),
]

description = Help.describe(Help.kai).concat(
	\\
	\\
	\\Kaifile.roc starts with:
	\\${Help.header}
	\\
	\\Set ROC to choose the Roc compiler (default: roc).
	\\Put arguments for a shell command or task after --.
	,
)

Parsed : {
	file : Try(Str, [NoValue]),
	no_color : Bool,
	json : Bool,
	backend : Try(Str, [NoValue]),
	command : Command,
}

# When Kaifile.roc loads, its shells, tasks, builds and workflows become
# subcommands so help and usage errors list what the project defines.
# Otherwise, or when a name is not a valid subcommand, the parsers are
# generic and the help says why.
parser : Try(Ir, _), [Color, Plain] -> Cli.CliParser(Parsed)
parser = |loaded, text_style| {
	generic = |note| {
		commands = [generic_shell, generic_run, generic_build, generic_workflow]
		Cli.assert_valid(cli(commands, note, text_style))
	}
	match loaded {
		Ok(ir) => {
			commands = [
				if ir.shells.is_empty() generic_shell else project_shell(ir),
				if ir.tasks.is_empty() generic_run else project_run(ir),
				if ir.builds.is_empty() generic_build else project_build(ir),
				if ir.workflows.is_empty() {
					generic_workflow
				} else {
					project_workflow(ir)
				},
			]
			cli(commands, "", text_style) ?? generic(
				"Kaifile.roc names are not all valid subcommands, so they "
					.concat("aren't listed."),
			)
		}
		Err(NoKaifile(_)) => generic("There is no Kaifile.roc here.")
		Err(_) => generic(
			"Kaifile.roc could not be loaded, so its shells, tasks and builds "
				.concat("aren't listed; run `kai check` for details."),
		)
	}
}

cli = |commands, note, text_style|
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
				help: "Use nix or guix instead of choosing automatically.",
			}),
			command: SubCmd.required(
				commands.concat([
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
			),
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

build_description = Help.describe(Help.build)

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

generic_build = SubCmd.finish(
	Param.str({ name: "name", help: "The build to run.", default: NoDefault }),
	{ name: "build", description: build_description, mapper: |name| Build(name) },
)

project_build = |ir|
	SubCmd.finish(
		SubCmd.required(
			ir.builds.map(
				|build|
					SubCmd.empty({
						name: build.name,
						description: "Output ${build.output} [${build.environment}]",
						value: Build(build.name),
					}),
			),
		),
		{ name: "build", description: build_description, mapper: |c| c },
	)

workflow_description = Help.describe(Help.workflow)

generic_workflow = SubCmd.finish(
	Param.str({
		name: "name",
		help: "The workflow to run.",
		default: NoDefault,
	}),
	{
		name: "workflow",
		description: workflow_description,
		mapper: |name| Workflow(name),
	},
)

project_workflow = |ir|
	SubCmd.finish(
		SubCmd.required(
			ir.workflows.map(
				|workflow|
					SubCmd.empty({
						name: workflow.name,
						description: Str.join_with(
							workflow.steps.map(
								|step|
									match step {
										RunTask(task, _) => "run ${task}"
										BuildArtifact(build) => "build ${build}"
										RunWorkflow(name) => "workflow ${name}"
									},
							),
							", ",
						),
						value: Workflow(workflow.name),
					}),
			),
		),
		{ name: "workflow", description: workflow_description, mapper: |c| c },
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

# --no-color decides how help renders and --json how even usage errors are
# reported, so both are also found before parsing.
requests : List(Str), Str -> Bool
requests = |args, flag|
	match args {
		[] | ["--", ..] => Bool.False
		[arg, .. as rest] => arg == flag or requests(rest, flag)
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
	shown = args.map(OsStr.display)
	mode = if requests(shown, "--json") Json else Human
	text_style = Help.text_style({
		terminal: is_terminal!("1") and is_terminal!("2"),
		no_color: Env.var_str!("NO_COLOR") ?? "",
		flag: requests(shown, "--no-color") or mode == Json,
	})
	located = Load.project!(requested_file(shown))
	loaded = match located {
		Ok(project) => Load.ir!(project)
		Err(err) => Err(err)
	}
	parsed = display(parser(loaded, text_style), args, OsStr.to_raw)
	match parsed {
		Err(Help(message)) | Err(Version(message)) =>
			Stdout.line!(message).map_err(|_| Exit(1))
		Err(InvalidUsage(message)) => {
			_ = match mode {
				Human => Stderr.line!(message)
				Json => Stdout.line!(Output.error("InvalidUsage", message, 2))
			}
			Err(Exit(2))
		}
		Ok({ command, backend, .. }) =>
			match run!(command, backend, located, loaded, mode) {
				Ok({}) => Ok({})
				Err(err) => {
					code = exit_status(err)
					_ = match mode {
						Human => Stderr.line!("kai: ${describe(err)}")
						Json =>
							Stdout.line!(
								Output.error(Str.inspect(err), describe(err), code),
							)
						}
					Err(Exit(code))
				}
			}
		}
}

run! = |command, backend, located, loaded, mode| {
	choice = backend_choice(backend)?
	project = located?
	execute! = |request|
		Execute.select!(loaded?, request, choice, project.root, mode)
	match command {
		Check => {
			Load.check!(project, mode)?
			_ = loaded?
			valid = "${project.file} is valid"
			Output.result!(
				mode,
				valid,
				Output.event("check", valid, [("file", Output.text(project.file))]),
			)
		}
		PrintIr => {
			ir = loaded?.to_str()
			match mode {
				Human => Stdout.write!(ir)
				Json => Stdout.line!(Output.event("ir", ir, []))
			}
		}
		UpdateLock => {
			ir = loaded?
			Selection.lockable(choice, ir)?
			layout = Workspace.locate!(project.root)?
			Update.update!(ir, layout)?
			updated = "updated ${layout.lock_path}"
			Output.result!(
				mode,
				updated,
				Output.event("update", updated, [("lock", Output.text(layout.lock_path))]),
			)
		}
		Shell(name, shell_command) => execute!(Request.Shell(name, shell_command))
		Run(task, args) => execute!(Request.Run(task, args))
		Build(name) => execute!(Request.Build(name))
		Workflow(name) => execute!(Request.Workflow(name))
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
			"could not run the Roc compiler `${compiler}` (${message}); "
				.concat(needs_compiler)
		CompilerMismatch(compiler, actual) =>
			"`${compiler}` is ${actual}; ${needs_compiler}"
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
		ChildExited(Shell(name), code) =>
			"shell ${name} exited with code ${code.to_str()}"
		ChildExited(Run(name), code) =>
			"task ${name} exited with code ${code.to_str()}"
		ChildExited(Build(name), code) =>
			"build ${name} exited with code ${code.to_str()}"
		SnapshotFailed(message) => message
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

needs_compiler =
	"kai evaluates Kaifile.roc with Roc ${Load.pinned_compiler}; put it on "
		.concat("PATH or set ROC to its path")

test_ir = Ir.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (shells (((name "default") (environment "dev"))
	\\  ((name "ci") (environment "dev"))))
	\\ (tasks (((name "args") (environment "dev") (run ("echo")))))
	\\ (builds (((name "app") (environment "dev") (inputs ()) (needs ())
	\\  (run ("true")) (output "out"))))
	\\ (workflows (((name "ci")
	\\  (steps ((RunTask "args" ()) (BuildArtifact "app")))))))
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
	(["build", "app"], Build("app")),
	(["workflow", "ci"], Workflow("ci")),
	(["--json", "run", "args", "--", "--json"], Run("args", ["--json"])),
	(["workflow", "ci", "--json"], Workflow("ci")),
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
	(["build", "anything"], Build("anything")),
	(["workflow", "anything"], Workflow("anything")),
	(["shell"], Shell("default", [])),
].all(|(args, expected)| parses(Err(NoKaifile("/x")), args, expected))

# Project-aware parsing rejects names the configuration does not define.
expect [
	["run", "missing"],
	["shell", "missing"],
	["run"],
	["build", "missing"],
	["build"],
	["workflow", "missing"],
	["workflow"],
].all(
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

# --no-color and --json are kai's only before --; after it, they are the
# task's.
expect [
	(["run", "t", "--no-color"], "--no-color", Bool.True),
	(["run", "t", "--", "--no-color"], "--no-color", Bool.False),
	(["--json", "check"], "--json", Bool.True),
	(["workflow", "ci", "--json"], "--json", Bool.True),
	(["run", "t", "--", "--json"], "--json", Bool.False),
	(["run", "t", "--jsonl"], "--json", Bool.False),
].all(|(args, flag, expected)| requests(args, flag) == expected)

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
			(["build"], Help.build),
			(["workflow"], Help.workflow),
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
