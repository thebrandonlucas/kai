# Run a built `kai workflow` and `kai --json` against real Nix on a copy of
# examples/artifacts: steps run in order, a failing step stops the rest and
# keeps its exit code, repeated steps repeat, each build snapshots the project
# afresh, a changed locked source stops a workflow before its first effect,
# and the lock is never written. In JSON mode kai's stdout is whole JSON
# objects without terminal escapes.
import pf.Cmd
import pf.Path
import pf.Stdout
import nix.LockJson

import KaiUpdate

KaiWorkflow := [].{
	run! = |binary| {
		(kai, project) = KaiUpdate.fixture!(
			binary,
			"artifacts",
			["assets", "src"],
		)?
		result = KaiWorkflow.run_in!(kai, project)
		Path.delete_all!(project)?
		result
	}

	# Test-only tasks and workflows, beside the example's own: mark appends
	# its arguments as one line to markers.txt, and edit changes the source
	# the library is built from.
	extra =
		\\	Task("mark", [Use("dev"),
		\\		Run(["sh", "-c", "echo \\"$*\\" >> markers.txt", "mark"])]),
		\\	Task("edit", [Use("dev"),
		\\		Run(["sh", "-c", "echo edited revision > src/message.txt"])]),
		\\	Task("fail", [Use("dev"), Run(["sh", "-c", "exit 7"])]),
		\\	Workflow("order", [RunTask("mark", ["one"]), BuildArtifact("library"),
		\\		RunTask("mark", ["two"])]),
		\\	Workflow("stops", [RunTask("mark", ["first"]), RunTask("fail", []),
		\\		RunTask("mark", ["never"])]),
		\\	Workflow("repeat", [RunTask("mark", ["again"]),
		\\		RunTask("mark", ["again"])]),
		\\	Workflow("fresh", [BuildArtifact("library"), RunTask("edit", []),
		\\		BuildArtifact("app")]),

	# Kai's stdout in JSON mode: whole lines, each a JSON object with a string
	# type, and no terminal escapes.
	events : List(U8) -> Try(List(LockJson), Str)
	events = |bytes| {
		if bytes.contains(27) {
			return Err("escape byte in JSON output")
		}
		utf8 = Str.from_utf8(bytes).map_err(|_| "JSON output is not UTF-8")?
		if !utf8.ends_with("\n") {
			return Err("JSON output does not end with a newline")
		}
		var $parsed = []
		for line in utf8.drop_suffix("\n").split_on("\n") {
			value = LockJson.decode(line)?
			_ = LockJson.string(LockJson.field(value, "type")?)?
			$parsed = $parsed.append(value)
		}
		Ok($parsed)
	}

	text : LockJson, Str -> Str
	text = |value, name|
		LockJson.string(LockJson.field(value, name) ?? LockJson.Null) ?? ""

	run_in! = |kai, project| {
		kaifile = Path.join(project, "Kaifile.roc")
		config = match Path.read_utf8!(kaifile)?.split_on("\n]\n") {
			[body, ""] => "${body}\n${KaiWorkflow.extra}\n]\n"
			_ => return Err(UnexpectedKaifileEnd)
		}
		Path.write_utf8!(kaifile, config)?
		file = |relative| Path.join(project, relative)
		kai! = |args| Cmd.new(Path.to_os_str(kai)).args_str(args).cwd(project)
			.run!()
		# Runs kai with --json, expecting its exit code and event types.
		json! = |args, code, types| {
			output = kai!(["--json"].concat(args))?
			parsed = KaiWorkflow.events(output.stdout_bytes)
				.map_err(|message| BadJson(args, message, KaiWorkflow.show(output)))?
			found = parsed.map(|event| KaiWorkflow.text(event, "type"))
			if output.status != Exited(code) or found != types {
				return Err(UnexpectedEvents(args, found, KaiWorkflow.show(output)))
			}
			Ok(parsed)
		}
		markers = file("markers.txt")
		marked! = |expected| {
			actual = Path.read_utf8!(markers) ?? ""
			if Path.exists!(markers)? {
				Path.delete!(markers)?
			}
			if actual != expected Err(WrongMarkers(expected, actual)) else Ok({})
		}
		# Each artifact's bytes, in the order kai built them.
		built! = |reported, expected| {
			artifacts = reported.keep_if(
				|e| KaiWorkflow.text(e, "type") == "artifact",
			)
			var $actual = []
			for artifact in artifacts {
				path = Path.utf8(KaiWorkflow.text(artifact, "path"))
				$actual = $actual.append(Path.read_utf8!(path)?)
			}
			if $actual != expected Err(WrongArtifacts($actual)) else Ok({})
		}
		_ = json!(["check"], 0, ["check"])?
		_ = json!(["update"], 0, ["update"])?
		lock = file(".kai/lock.json")
		published = Path.read_bytes!(lock)?
		modified = Path.time_modified!(lock)?
		step = ["step_started", "step_finished"]
		library = "HELLO FROM THE WORKING TREE\n"
		ordered = json!(
			["workflow", "order"],
			0,
			["backend"].concat(step)
				.concat(["step_started", "artifact", "step_finished"])
				.concat(step),
		)?
		marked!("one\ntwo\n")?
		built!(ordered, [library])?
		# The failing step's exit code is kai's; later steps never run.
		stopped = json!(
			["workflow", "stops"],
			7,
			["backend"].concat(step).concat(["step_started", "error"]),
		)?
		marked!("first\n")?
		failure = stopped.last() ?? LockJson.Null
		if
			KaiWorkflow.text(failure, "error") != "child_exited"
				or LockJson.field(failure, "exit_code") != Ok(LockJson.Number("7"))
				{
					return Err(WrongError(LockJson.encode(failure)))
				}
		_ = json!(["run", "fail"], 7, ["backend", "error"])?
		_ = json!(["workflow", "missing"], 2, ["error"])?
		# Repeated steps are repeated effects, reported on stderr for people.
		repeated = kai!(["workflow", "repeat"])?
		second = "kai: workflow repeat step 2/2: run mark"
		if
			repeated.status != Exited(0)
				or !Str.from_utf8_lossy(repeated.stderr_bytes).contains(second)
				{
					return Err(NotRepeated(KaiWorkflow.show(repeated)))
				}
		marked!("again\nagain\n")?
		# A changed locked source stops the workflow before its first task.
		heading = file("assets/heading.txt")
		original = Path.read_bytes!(heading)?
		Path.write_utf8!(heading, "Changed heading\n")?
		locked = json!(
			["workflow", "stops"],
			1,
			["backend", "step_started", "error"],
		)?
		if
			!KaiWorkflow.text(locked.last() ?? LockJson.Null, "message")
				.contains("run `kai update`")
				{
					return Err(LockedSourceIgnored(locked.map(LockJson.encode)))
				}
		marked!("")?
		Path.write_bytes!(heading, original)?
		# A task between builds edits the project; the app's library sees it.
		fresh = json!(
			["workflow", "fresh"],
			0,
			["backend", "step_started", "artifact", "step_finished"]
				.concat(step)
				.concat(["step_started", "artifact", "step_finished"]),
		)?
		edited = "EDITED REVISION\n"
		built!(fresh, [library, "Artifact example\n${edited}"])?
		rebuilt = json!(["build", "library"], 0, ["backend", "artifact"])?
		built!(rebuilt, [edited])?
		# People get the task's output and the store path on stdout.
		ci = kai!(["workflow", "ci"])?
		ci_app = match Str.from_utf8_lossy(ci.stdout_bytes).split_on("\n") {
			["source checked", path, ""] if ci.status == Exited(0) =>
				Path.read_utf8!(Path.utf8(path))?
			_ => ""
		}
		if ci_app != "Artifact example\n${edited}" {
			return Err(WrongCiOutput(KaiWorkflow.show(ci)))
		}
		if
			Path.read_bytes!(lock)? != published
				or Path.time_modified!(lock)? != modified
				{
					return Err(LockChanged)
				}
		Stdout.line!(
			"kai workflow kept order, exit codes and fresh builds; --json is JSONL",
		)
	}

	show = |output|
		Str.inspect(output.status)
			.concat("\n${Str.from_utf8_lossy(output.stdout_bytes)}")
			.concat(Str.from_utf8_lossy(output.stderr_bytes))
}

# Only whole JSON object lines with a type, and no escapes, are JSON output.
expect [
	("{\"type\":\"check\"}\n{\"type\":\"error\",\"exit_code\":2}\n", Bool.True),
	("{\"type\":\"check\"}", Bool.False),
	("source checked\n{\"type\":\"check\"}\n", Bool.False),
	("{\"message\":\"no type\"}\n", Bool.False),
	("{\"type\":\"note\",\"message\":\"\u(001b)[31m\"}\n", Bool.False),
].all(|(text, ok)| KaiWorkflow.events(text.to_utf8()).is_ok() == ok)
