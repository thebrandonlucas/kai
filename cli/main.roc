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
}

import pf.Env
import pf.OsStr
import pf.Stderr
import pf.Stdout
import weaver.Cli
import weaver.Opt
import weaver.Param
import weaver.SubCmd
import ir.Ir
import ir.Request

import Execute
import Load
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

description =
	\\Developer environments, tasks and builds from a Kaifile.roc.
	\\
	\\Set ROC to choose the Roc compiler (default: roc).
	\\Put arguments for a shell command or task after --.

Parsed : { file : Try(Str, [NoValue]), command : Command }

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
			command: SubCmd.required([
				shell,
				run,
				SubCmd.empty({
					name: "check",
					description: "Validate Kaifile.roc with the Roc compiler",
					value: Check,
				}),
				SubCmd.empty({
					name: "ir",
					description: "Print the validated Kaifile IR",
					value: PrintIr,
				}),
				SubCmd.empty({
					name: "update",
					description: "Resolve dependency pins into the lock file",
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

shell_description = "Enter a shell, or run a command inside it"

run_description = "Run a task in its environment"

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
			description: "${shell_description} (default: default)",
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

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	text_style = match Env.var_str!("NO_COLOR") {
		Ok(value) if !value.is_empty() => Plain
		_ => Color
	}
	located = Load.project!(requested_file(args.map(OsStr.display)))
	loaded = match located {
		Ok(project) => Load.ir!(project)
		Err(err) => Err(err)
	}
	parsed = Cli.parse_or_display_message(
		parser(loaded, text_style),
		args,
		OsStr.to_raw,
	)
	match parsed {
		Err(Help(message)) | Err(Version(message)) =>
			Stdout.line!(message).map_err(|_| Exit(1))
		Err(InvalidUsage(message)) => {
			_ = Stderr.line!(message)
			Err(Exit(2))
		}
		Ok({ command, .. }) =>
			match run!(command, located, loaded) {
				Ok({}) => Ok({})
				Err(err) => {
					_ = Stderr.line!("kai: ${describe(err)}")
					Err(Exit(exit_status(err)))
				}
			}
		}
}

run! = |command, located, loaded| {
	project = located?
	match command {
		Check => {
			Load.check!(project)?
			_ = loaded?
			Stdout.line!("${project.file} is valid")
		}
		PrintIr => Stdout.write!(loaded?.to_str())
		UpdateLock => {
			layout = Workspace.locate!(project.root)?
			Update.update!(loaded?, layout)?
			Stdout.line!("updated ${layout.lock_path}")
		}
		Shell(name, shell_command) =>
			Execute.request!(
				loaded?,
				Request.Shell(name, shell_command),
				Workspace.locate!(project.root)?,
			)
		Run(task, args) =>
			Execute.request!(
				loaded?,
				Request.Run(task, args),
				Workspace.locate!(project.root)?,
			)
		}
}

exit_status = |err|
	match err {
		ChildExited(_, code) => Execute.exit_code(code)
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
		other => Str.inspect(other)
	}

test_ir = Ir.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (shells (((name "default") (environment "dev"))
	\\  ((name "ci") (environment "dev"))))
	\\ (tasks (((name "args") (environment "dev") (run ("echo"))))))
	,
)

parse = |loaded, args|
	Cli.parse_or_display_message(parser(loaded, Plain), args, |a| Utf8(a))

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

# A failing child's status becomes kai's; every other failure is 1.
expect exit_status(ChildExited(Run("fail"), 7)) == 7
	and exit_status(NoLock("/p/.kai/lock.json")) == 1
