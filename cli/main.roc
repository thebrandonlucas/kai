# kai: developer environments, tasks and builds from a Kaifile.roc.
app [main!] {
	api: "../platform/api.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Stderr
import pf.Stdout
import api.Layout
import api.LockJson
import api.Protocol

import BuildRunner
import Execute
import Help
import Load
import Output
import PluginBundle
import Selection
import Update
import Variables
import Workspace

import "../VERSION" as canonical_version : Str

version = canonical_version.trim()

# Whether kai's own stdin ("0"), stdout ("1") or stderr ("2") is a terminal.
# `test` inherits kai's streams: by default Cmd.run! gives it a null stdin and
# captures its stdout and stderr, so it never saw a terminal.
is_terminal! = |descriptor| {
	test = Cmd.new("test").args(["-t", OsStr.from_str(descriptor)])
	match test.inherit_stdio().run!() {
		Ok(output) => output.status == Exited(0)
		Err(_) => Bool.False
	}
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
	mode = if (requests(shown, "--json")) Json else Human
	match run!(shown, mode) {
		Ok({}) => Ok({})
		Err(Usage(message)) => {
			_ = match mode {
				Human => Stderr.line!(message)
				Json =>
					Stderr.line!(
						Output.error({
							code: "invalid_usage",
							message,
							exit_code: 2,
							hint: "",
							suggestions: suggestions(message),
						}),
					)
			}
			Err(Exit(2))
		}
		Err(err) => {
			exit_code = exit_status(err)
			message = describe(err)
			_ = match mode {
				Human => Stderr.line!("kai: ${message}")
				Json =>
					Stderr.line!(
						Output.error({
							code: error_code(err),
							message,
							exit_code,
							hint: hint(err),
							suggestions: [],
						}),
					)
			}
			Err(Exit(exit_code))
		}
	}
}

# kai finds its own flags before asking the Kaifile: --file names it, and
# `check`, --version and help work even when it does not compile.
run! = |shown, mode| {
	if requests(shown, "--version") or requests(shown, "-V") {
		return Stdout.line!(version)
	}
	# Without a command, a person at a terminal gets concise help and a
	# script a usage error, whether or not there is a Kaifile.roc.
	if command_word(shown).is_err() and !asks_help(shown) {
		if mode == Human and is_terminal!("1") {
			return Stdout.line!(Help.concise(version))
		}
		return Err(Usage(Help.needs_command))
	}
	if command_word(shown) == Ok("init") and !asks_help(shown) {
		return init!(requested_file(shown), mode)
	}
	if command_word(shown) == Ok("bundle-plugin") {
		if asks_help(shown) {
			return Stdout.line!(Help.bundle_plugin)
		}
		return bundle_plugin!(bundle_arguments(shown, [], Err(NoValue))?, mode)
	}
	located = Load.project!(requested_file(shown))
	if command_word(shown) == Ok("check") and !asks_help(shown) {
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
			return Stdout.line!(Help.generic(version, Help.starter))
		Err(err) => return Err(err)
	}
	layout = Workspace.locate!(project.root)?
	style = Help.text_style({
		terminal: is_terminal!("1") and is_terminal!("2"),
		no_color: Variables.read!(Variables.no_color) ?? "",
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
		# kai knows the release URLs a Kaifile.roc starts with; the platform
		# cannot name its own bundle.
		Help(text) if command_word(shown).is_err() =>
			Stdout.line!("${Help.versioned(text, version)}\n\n${Help.notes}")
		Help(text) => Stdout.line!(Help.versioned(text, version))
		Usage(text) => Err(Usage(text))
		Refused(text) => Err(Refused(text))
		Describe({ plugins, commands, backends }) => {
			versioned = |p|
				if (p.version.is_empty()) p.name else "${p.name} ${p.version}"
			named = plugins.map(versioned)
			lines = [
				"plugins: ${Str.join_with(named, ", ")}",
				"commands: ${Str.join_with(commands, ", ")}",
				"backends: ${Str.join_with(backends, ", ")}",
			]
			texts = |items| LockJson.Array(items.map(|i| LockJson.String(i)))
			fields = [
				("plugins", texts(plugins.map(|p| p.name))),
				("commands", texts(commands)),
				("backends", texts(backends)),
			]
			summary = Str.join_with(lines, "\n")
			event = Output.event("describe", "Kaifile.roc", fields)
			Output.result!(mode, summary, event)
		}
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
				if (command == "workflow") operand(shown) else "",
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
		working_directory: Env.cwd!()?.to_str()?,
		style,
		host: { system },
		layout,
		revision: revision!(layout.project_root),
		lock,
		resume,
	}
	Load.ask!(project, request)
}

# The project's revision, for builds that stamp it; empty outside git or
# when git is not installed.
revision! : Str => { describe : Str, commit_date : Str }
revision! = |root| {
	git! = |args|
		Cmd.new("git").args(args).cwd(Workspace.path(root)).stderr(Null).capture!()
			.map_ok(Str.trim)
			?? ""
	{
		describe: git!(["describe", "--tags", "--always", "--dirty"]),
		commit_date: git!(["log", "-1", "--format=%cs"]),
	}
}

# Help without a Kaifile to ask is kai's generic help.
asks_help : List(Str) -> Bool
asks_help = |args|
	requests(args, "--help") or requests(args, "-h")

# The first word that is not one of kai's options, and the one after it.
command_word : List(Str) -> Try(Str, [NoCommand])
command_word = |args|
	match args {
		[] | ["--", ..] => Err(NoCommand)
		["-f", _, .. as rest] | ["--file", _, .. as rest] => command_word(rest)
		["--backend", _, .. as rest] => command_word(rest)
		[arg, .. as rest] => if (arg.starts_with("-")) command_word(rest) else Ok(arg)
	}

operand : List(Str) -> Str
operand = |args|
	match args {
		[] | ["--", ..] => ""
		["-f", _, .. as rest] | ["--file", _, .. as rest] => operand(rest)
		["--backend", _, .. as rest] => operand(rest)
		[arg, .. as rest] =>
			if (arg.starts_with("-")) operand(rest) else command_word(rest) ?? ""
	}

# `kai init`: write a starting Kaifile.roc, never replacing an existing file.
init! = |requested, mode| {
	cwd = Env.cwd!()?.to_str()?
	location = Load.resolve(cwd, requested ?? Load.default_file)
	if Load.path(location).exists!() ?? Bool.True {
		return Err(KaifileExists(location))
	}
	# The project is named after its directory, as a starting point.
	name = Load.split_file(location).root.split_on("/").last() ?? "project"
	Load.path(location).write_utf8!(Help.kaifile(name))?
	created = "Created ${location}."
	Output.result!(
		mode,
		"${created}\n${Help.next_steps}",
		Output.event("init", created, [("file", Output.text(location))]),
	)
}

# `kai bundle-plugin`: bundle a plugin for this kai's release, by default
# into the plugin's own directory.
bundle_plugin! = |{ plugin, output }, mode| {
	cwd = Env.cwd!()?.to_str()?
	directory = Load.path(Load.resolve(cwd, plugin)).canonicalize!()?.to_str()?
	target = Load.resolve(cwd, output ?? directory)
	bundle = PluginBundle.create!(directory, target)?
	name = directory.split_on("/").last() ?? "plugin"
	file = bundle.split_on("/").last() ?? bundle
	bundled = "Bundled ${bundle}."
	summary =
		\\${bundled}
		\\Host it at a URL ending in its file name, and add it to the header of a
		\\Kaifile.roc that uses this kai's platform and std:
		\\  ${name}: "https://…/${file}",
	Output.result!(
		mode,
		summary,
		Output.event(
			"bundle-plugin",
			bundled,
			[("file", Output.text(bundle)), ("name", Output.text(name))],
		),
	)
}

# bundle-plugin's directory and --output-dir, among kai's own options.
bundle_arguments = |args, words, output|
	match args {
		[] =>
			match words {
				[_] => Ok({ plugin: ".", output })
				[_, plugin] => Ok({ plugin, output })
				_ => Err(Usage(Help.bundle_plugin))
			}
		["--output-dir", value, .. as rest] =>
			bundle_arguments(rest, words, Ok(value))
		["--json", .. as rest] | ["--no-color", .. as rest] =>
			bundle_arguments(rest, words, output)
		[arg, .. as rest] =>
			if arg.starts_with("-") {
				Err(Usage(Help.bundle_plugin))
			} else {
				bundle_arguments(rest, words.append(arg), output)
			}
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

# kai's exit codes, as the README's Exit codes lists them: a failing child's
# status, 2 for a usage error, 6 when a step needs confirmation, else 1.
exit_status = |err|
	match err {
		ChildExited(_, code) => Execute.exit_code(code)
		Refused(_) => 2
		ConfirmationRequired(_) => 6
		_ => 1
	}

# The `error` of a --json error, as the README's Exit codes lists them. They
# are kai's interface, so they never follow a rename in the code.
error_code = |err|
	match err {
		Refused(_) => "refused"
		NoKaifile(_) => "no_kaifile"
		NotAnApp(_) => "not_a_kaifile"
		KaifileExists(_) => "kaifile_exists"
		KaifileInvalid(_, _) | KaifileFailed(_, _, _) | PreviousHeader =>
			"kaifile_invalid"
		IncompatibleProtocol(_, _) => "incompatible_protocol"
		CompilerUnavailable(_, _) | CompilerMismatch(_, _) | NixMissing =>
			"no_compiler"
		UnsupportedHost => "unsupported_host"
		NoPlatformReference(_) | BundleFailed(_) => "bundle_failed"
		BadResponse(_) | AnswerTooLarge(_) => "bad_response"
		InvalidProject(_) | InvalidWorkspace(_) => "invalid_project"
		UnsafeWorkspace(_) | UnsafePath(_) | UnsafePlan(_) => "unsafe"
		MissingSource(_) => "missing_source"
		LocalChanged(_, _) => "stale_lock"
		LockFailed(_) => "lock_failed"
		UpdateLocked(_) | AuthorityChanged => "update_conflict"
		ConfirmationRequired(_) => "confirmation_required"
		Declined(_) => "declined"
		ChildExited(_, _) => "child_exited"
		MissingSecret(_, _) => "missing_secret"
		InvalidDotenv(_) => "invalid_dotenv"
		BackendConflict(_, _) | NoEligibleBackend(_) => "no_backend"
		RequiredBackendUnavailable(_, _) => "no_backend"
		NoImplementation(_) => "no_implementation"
		PlanFailed(_) | RenderFailed(_) | SnapshotFailed(_) => "plan_failed"
		_ => "failed"
	}

# The fix for a --json error, when kai knows one: usually a command to run.
# A plan names its fix as "run `command`".
hint = |err|
	match err {
		NoKaifile(_) => "kai init"
		KaifileFailed(_, _, _) => "kai check"
		LocalChanged(_, update) => update
		AuthorityChanged => "kai update"
		ConfirmationRequired(_) => "pass --yes"
		PlanFailed(message) => named_fix(message)
		_ => ""
	}

named_fix : Str -> Str
named_fix = |message|
	match message.split_on("run `") {
		[_, .., after] => after.split_first("`").map_ok(|found| found.before) ?? ""
		_ => ""
	}

# The names a usage error suggests for a mistyped one, as it words them:
# "did you mean `a` or `b`?".
suggestions : Str -> List(Str)
suggestions = |message|
	match message.split_first("did you mean ") {
		Ok({ after, .. }) =>
			(after.split_first("?").map_ok(|found| found.before) ?? "")
				.split_on("`")
				.drop_if(|part| part.is_empty() or part.starts_with(" "))
		Err(_) => []
	}

describe : _ -> Str
describe = |err|
	match err {
		NoKaifile(location) => "no Kaifile.roc at ${location}"
		KaifileExists(location) =>
			"${location} already exists; kai init never replaces a file"
		NoPlatformReference(file) =>
			"${file} names no platform; a plugin's header has `pf: platform \"…\"`"
		BundleFailed(output) => "roc bundle failed:\n${output}"
		PreviousHeader =>
			"Kaifile.roc uses the pre-plugin header `app [config]`; start it as "
				.concat("`kai --help` shows and wrap the settings in ")
				.concat("`kaifile = Std.kaifile([...])`")
		NotAnApp(file) =>
			"${file} has no `app [kaifile]` header, so it is not a Kaifile; "
				.concat("run kai in a project directory or pass one with -f")
		UnsupportedHost =>
			"Kai runs only on x86_64 and aarch64 Linux and Apple Silicon macOS hosts"
		CompilerUnavailable(compiler, message) =>
			"could not run the Roc compiler `${compiler}` (${message}); "
				.concat(needs_compiler)
		CompilerMismatch(compiler, actual) =>
			"`${compiler}` is ${actual}; ${needs_compiler}"
		NixMissing => "Nix is not installed; ${needs_compiler}"
		KaifileInvalid(file, releases) =>
			"${file} did not compile; see the errors above${mixed(releases)}"
		KaifileFailed(file, output, releases) =>
			"${file} did not compile:\n${output}${mixed(releases)}${unbuilt(output)}"
		IncompatibleProtocol(major, minor) => {
			theirs = "${major.to_str()}.${minor.to_str()}"
			own = Protocol.current.major.to_str()
			ours = "${own}.0 to ${own}.${Protocol.current.minor.to_str()}"
			"Kaifile.roc's platform speaks protocol ${theirs}, and this kai ${ours}; "
				.concat("use a kai of that platform's release, or this kai's platform ")
				.concat("and std (${Load.release}), as `kai --help` shows")
		}
		BadResponse(reason) => "could not read the Kaifile's answer: ${reason}"
		AnswerTooLarge(size) =>
			"the Kaifile's answer is ${(size // 1048576).to_str()} MiB, over kai's "
				.concat("64 MiB limit; a workflow may repeat a large step too often")
		Refused(message) => message
		InvalidProject(message) => "invalid Kaifile: ${message}"
		InvalidWorkspace(message) => "invalid workspace: ${message}"
		UnsafeWorkspace(message) => "unsafe workspace: ${message}"
		UnsafePath(value) => "refusing unsafe or symlinked path: ${value}"
		RenderFailed(message) => "cannot generate the Nix files: ${message}"
		LockFailed(message) => "cannot lock the Nix inputs: ${message}"
		LocalChanged(path, update) =>
			"local source ${path} changed; run `${update}`"
		MissingSource(path) => "local source or overlay ${path} does not exist"
		UnsafePlan(why) => "refusing the plan: ${why}"
		ConfirmationRequired(prompt) =>
			"${prompt} needs confirmation; pass --yes to accept"
		Declined(prompt) => "not confirmed: ${prompt}"
		SnapshotFailed(message) => message
		ChildExited(description, code) =>
			"${description} exited with code ${code.to_str()}"
		MissingSecret(description, name) =>
			"${description} needs secret ${name}; set it in .env or kai's environment"
		InvalidDotenv(line) => ".env line ${line.to_str()} is not NAME=value"
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
		NoImplementation("") => "no plugin implements this command"
		NoImplementation(backend) => "no plugin implements this command on ${backend}"
		other => Str.inspect(other)
	}

# What to do about bundles from releases other than this kai's.
mixed : List(Str) -> Str
mixed = |releases|
	if releases.is_empty() {
		""
	} else {
		named = Str.join_with(releases, " and ")
		"\nIts header names bundles from ${named}; use those of this "
			.concat("kai's release, ${Load.release}, as `kai --help` shows")
	}

# A Kaifile naming a Kai checkout's platform by path needs that platform's
# host built; roc reports only the missing linker inputs.
unbuilt : Str -> Str
unbuilt = |output|
	if output.contains("missing target file") {
		"\nIf its platform is a Kai checkout's, build the platform host first: "
			.concat("`zig build --release` in its platform directory")
	} else {
		""
	}

needs_compiler =
	"kai evaluates Kaifile.roc with Roc ${Load.pinned_compiler}; put it on "
		.concat("PATH, set ROC to its path, or install Nix ")
		.concat("(https://nixos.org/download) for kai to get it")

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

# bundle-plugin takes a directory and --output-dir among kai's own options.
expect [
	(["bundle-plugin"], Ok({ plugin: ".", output: Err(NoValue) })),
	(
		["--json", "bundle-plugin", "p", "--output-dir", "o"],
		Ok({ plugin: "p", output: Ok("o") }),
	),
	(["bundle-plugin", "p", "q"], Err(Usage(Help.bundle_plugin))),
	(["bundle-plugin", "--yes"], Err(Usage(Help.bundle_plugin))),
].all(|(args, expected)| bundle_arguments(args, [], Err(NoValue)) == expected)

# A failing child's status becomes kai's, a refusal is a usage error, a
# needed confirmation is 6, and every other failure is 1.
expect exit_status(ChildExited("task fail", 7)) == 7
	and exit_status(Refused("--backend must be one of nix, guix")) == 2
	and exit_status(ConfirmationRequired("deploy?")) == 6
	and exit_status(PlanFailed("no lock file")) == 1

# A plan names its fix as "run `command`"; the last one is the hint.
expect [
	("no lock file at /p/.kai/lock.json; run `kai update`", "kai update"),
	("run `kai update a`, or run `kai update b`", "kai update b"),
	("no backend can serve this request", ""),
	("run `unclosed", ""),
].all(|(message, expected)| named_fix(message) == expected)

# A missing linker input hints at building a checkout's platform host.
expect unbuilt("── ✗ missing target file ──\n").contains("zig build --release")
	and unbuilt("── TYPE MISMATCH ──\n") == ""

# A usage error's suggestions are the names it asks about.
expect [
	("no task named mo; available tasks: moo; did you mean `moo`?", ["moo"]),
	("no task a; available tasks: b, c; did you mean `b` or `c`?", ["b", "c"]),
	("no task named zzz; available tasks: moo", []),
].all(|(message, expected)| suggestions(message) == expected)
