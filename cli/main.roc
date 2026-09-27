# kai: developer environments, tasks and builds from a Kaifile.roc.
app [main!] {
	pf: platform "../.basic-cli/main.roc",
	api: "../kaifile/platform/api.roc",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Stderr
import pf.Stdout
import api.Layout
import api.Protocol

import BuildRunner
import Execute
import Help
import Load
import Output
import Selection
import Update
import Workspace

import "../VERSION" as canonical_version : Str

version = canonical_version.trim()

is_terminal! = |descriptor|
	match Cmd.new_str("test").args_str(["-t", descriptor]).exec_exit_code!() {
		Ok(0) => Bool.True
		_ => Bool.False
	}

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	shown = args.map(OsStr.display)
	# Inside a build's sandbox; never parsed as a command or a Kaifile.
	match shown {
		[command, spec] if command == BuildRunner.command =>
			return BuildRunner.run!(spec)
		_ => {}
	}
	mode = if requests(shown, "--json") Json else Human
	match run!(shown, mode) {
		Ok({}) => Ok({})
		Err(Usage(message)) => {
			_ = match mode {
				Human => Stderr.line!(message)
				Json => Stdout.line!(Output.error("InvalidUsage", message, 2))
			}
			Err(Exit(2))
		}
		Err(err) => {
			code = exit_status(err)
			_ = match mode {
				Human => Stderr.line!("kai: ${describe(err)}")
				Json => Stdout.line!(Output.error(Str.inspect(err), describe(err), code))
			}
			Err(Exit(code))
		}
	}
}

# kai finds its own flags before asking the Kaifile: --file names it, and
# `check`, --version and help work even when it does not compile.
run! = |shown, mode| {
	if requests(shown, "--version") or requests(shown, "-V") {
		return Stdout.line!("kai ${version}")
	}
	located = Load.project!(requested_file(shown))
	if command_word(shown) == Ok("check") {
		project = located?
		Load.check!(project, mode)?
		valid = "${project.file} is valid"
		return Output.result!(
			mode,
			valid,
			Output.event("check", valid, [("file", Output.text(project.file))]),
		)
	}
	project = match located {
		Ok(found) => found
		Err(NoKaifile(_)) if asks_help(shown) =>
			return Stdout.line!(Help.generic(version, "There is no Kaifile.roc here."))
		Err(err) => return Err(err)
	}
	layout = Workspace.locate!(project.root)?
	style = Help.text_style({
		terminal: is_terminal!("1") and is_terminal!("2"),
		no_color: Env.var_str!("NO_COLOR") ?? "",
		flag: requests(shown, "--no-color") or mode == Json,
	})
	asked = { project, layout, shown, style }
	body = match ask!(asked, Fresh) {
		Ok(answered) => answered
		Err(err) =>
			if asks_help(shown) {
				return Stdout.line!(
					Help.generic(
						version,
						"Kaifile.roc could not be loaded, so its commands aren't "
							.concat("listed; run `kai check` for details."),
					),
				)
			} else {
				return Err(err)
			}
		}
	match body {
		Help(text) => Stdout.line!(text)
		Usage(text) => Err(Usage(text))
		Refused(text) => Err(Refused(text))
		Describe(_) => Err(Refused("kai has no use for a description here"))
		Candidates({ command, choice, lock, options, .. }) => {
			# A person can answer a confirmation only at a terminal, without
			# --json.
			interactive = mode == Human and is_terminal!("0") and is_terminal!("2")
			resume! = |backend, phase, observed|
				ask!(asked, Resume({ command, backend, phase, observed }))
			Execute.command!(
				{ choice, lock, options },
				resume!,
				layout,
				mode,
				{
					yes: requests(shown, "--yes"),
					dry_run: requests(shown, "--dry-run"),
					interactive,
				},
				# Workflow steps are reported under the name kai was given.
				if command == "workflow" operand(shown) else "",
			)
		}
	}
}

# The Kaifile's answer to the command line, fresh or continuing a plan.
Asked : {
	project : Load.Location,
	layout : Layout,
	shown : List(Str),
	style : [Color, Plain],
}

ask! :
	Asked,
	[
		Fresh,
		Resume(
			{
				command : Str,
				backend : Str,
				phase : U64,
				observed : List({ path : Str, contents : [Missing, Text(Str)] }),
			},
		),
	] => Try(Protocol.Body, _)
ask! = |{ project, layout, shown, style }, resume| {
	system = Load.system!()?
	lock = Update.text!(layout.lock_path)?
	request = Protocol.Request.{
		protocol: Protocol.current,
		argv: shown,
		style,
		host: { system },
		layout,
		lock,
		resume,
	}
	Load.ask!(project, request)
}

# Help without a Kaifile to ask is kai's generic help.
asks_help : List(Str) -> Bool
asks_help = |args|
	args.is_empty() or requests(args, "--help") or requests(args, "-h")

# The first word that is not one of kai's options, and the one after it.
command_word : List(Str) -> Try(Str, [NoCommand])
command_word = |args|
	match args {
		[] | ["--", ..] => Err(NoCommand)
		["-f", _, .. as rest] | ["--file", _, .. as rest] => command_word(rest)
		["--backend", _, .. as rest] => command_word(rest)
		[arg, .. as rest] => if arg.starts_with("-") command_word(rest) else Ok(arg)
	}

operand : List(Str) -> Str
operand = |args|
	match args {
		[] | ["--", ..] => ""
		["-f", _, .. as rest] | ["--file", _, .. as rest] => operand(rest)
		["--backend", _, .. as rest] => operand(rest)
		[arg, .. as rest] =>
			if arg.starts_with("-") operand(rest) else command_word(rest) ?? ""
		}

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

# kai's flags count only before --; after it they are the task's.
requests : List(Str), Str -> Bool
requests = |args, flag|
	match args {
		[] | ["--", ..] => Bool.False
		[arg, .. as rest] => arg == flag or requests(rest, flag)
	}

exit_status = |err|
	match err {
		ChildExited(_, code) => Execute.exit_code(code)
		Refused(_) => 2
		_ => 1
	}

describe : _ -> Str
describe = |err|
	match err {
		NoKaifile(location) => "no Kaifile.roc at ${location}"
		PreviousHeader =>
			"Kaifile.roc uses the pre-plugin header `app [config]`; start it as "
				.concat("`kai --help` shows and wrap the settings in ")
				.concat("`kaifile = Std.kaifile([...])`")
		UnsupportedHost =>
			"Kai runs only on x86_64 and aarch64 Linux hosts"
		CompilerUnavailable(compiler, message) =>
			"could not run the Roc compiler `${compiler}` (${message}); "
				.concat(needs_compiler)
		CompilerMismatch(compiler, actual) =>
			"`${compiler}` is ${actual}; ${needs_compiler}"
		KaifileInvalid(file) => "${file} did not compile; see the errors above"
		KaifileFailed(file, output) => "${file} did not compile:\n${output}"
		IncompatibleProtocol(major, minor) =>
			"Kaifile.roc uses platform protocol ${major.to_str()}.${minor.to_str()}; "
				.concat("this kai speaks ${Protocol.current.major.to_str()}.x")
		BadResponse(reason) => "could not read the Kaifile's answer: ${reason}"
		Refused(message) => message
		InvalidProject(message) => "invalid Kaifile: ${message}"
		InvalidWorkspace(message) => "invalid workspace: ${message}"
		UnsafeWorkspace(message) => "unsafe workspace: ${message}"
		UnsafePath(value) => "refusing unsafe or symlinked path: ${value}"
		RenderFailed(message) => "cannot generate the Nix files: ${message}"
		LockFailed(message) => "cannot lock the Nix inputs: ${message}"
		LocalChanged(path) => "local source ${path} changed; run `kai update`"
		UnsafePlan(why) => "refusing the plan: ${why}"
		ConfirmationRequired(prompt) =>
			"${prompt} needs confirmation; pass --yes to accept"
		Declined(prompt) => "not confirmed: ${prompt}"
		SnapshotFailed(message) => message
		ChildExited(what, code) => "${what} exited with code ${code.to_str()}"
		UpdateLocked(guard) =>
			"another kai update holds ${guard}; if none is running, it is "
				.concat("safe to remove that directory")
		AuthorityChanged => "the lock file changed during update; retry kai update"
		BackendConflict(backend, why) =>
			"--backend ${backend} cannot serve this request: ${why}"
		NoEligibleBackend(reasons) =>
			"no backend can serve this request:\n  "
				.concat(Str.join_with(reasons.keep_if(|r| !r.is_empty()), "\n  "))
		RequiredBackendUnavailable(backend, probe) =>
			"this request needs ${backend}, which "
				.concat(Selection.probe_text(probe))
		PlanFailed(message) => message
		other => Str.inspect(other)
	}

needs_compiler =
	"kai evaluates Kaifile.roc with Roc ${Load.pinned_compiler}; put it on "
		.concat("PATH or set ROC to its path")

# --file is found where the parser reads it, and never after --.
expect [
	(["-f", "a.roc", "check"], Ok("a.roc")),
	(["check", "--file", "b.roc"], Ok("b.roc")),
	(["--file=c.roc", "check"], Ok("c.roc")),
	(["run", "t", "--", "-f", "d.roc"], Err(NoValue)),
	(["check"], Err(NoValue)),
].all(|(args, expected)| requested_file(args) == expected)

# kai's flags are kai's only before --; after it, they are the task's.
expect [
	(["run", "t", "--no-color"], "--no-color", Bool.True),
	(["run", "t", "--", "--no-color"], "--no-color", Bool.False),
	(["--json", "check"], "--json", Bool.True),
	(["workflow", "ci", "--json"], "--json", Bool.True),
	(["run", "t", "--", "--json"], "--json", Bool.False),
	(["run", "t", "--jsonl"], "--json", Bool.False),
].all(|(args, flag, expected)| requests(args, flag) == expected)

# The command is the first word that is not one of kai's options.
expect [
	(["check"], Ok("check")),
	(["-f", "check", "run", "t"], Ok("run")),
	(["--backend", "guix", "--json", "workflow", "ci"], Ok("workflow")),
	(["--", "check"], Err(NoCommand)),
].all(|(args, expected)| command_word(args) == expected)
	and operand(["--json", "workflow", "ci", "--dry-run"]) == "ci"

# A failing child's status becomes kai's, a refusal is a usage error, and
# every other failure is 1.
expect exit_status(ChildExited("task fail", 7)) == 7
	and exit_status(Refused("--backend must be one of nix, guix")) == 2
		and exit_status(PlanFailed("no lock file")) == 1
