# Where kai's own messages go. For people, results go to stdout and progress
# and diagnostics to stderr. With --json, each one is instead a JSON object on
# its own stdout line, with its type and a readable message first. Children
# (tasks, shells and their commands) keep inheriting stdout and stderr in both
# modes: their bytes are the user's program output, which kai must neither
# rewrite, buffer nor detach from a terminal. Kai writes an event only
# between children, so its events stay whole lines.
import pf.Stderr
import pf.Stdout

import nix.LockJson

Output := [].{
	Mode : [Human, Json]

	event : Str, Str, List((Str, LockJson)) -> Str
	event = |type_name, message, fields|
		LockJson.encode(
			LockJson.Object(
				[
					("type", LockJson.String(type_name)),
					("message", LockJson.String(message)),
				]
					.concat(fields)
					.map(|(name, value)| { name, value }),
			),
		)

	text : Str -> LockJson
	text = |value| LockJson.String(value)

	number : I32 -> LockJson
	number = |value| LockJson.Number(value.to_str())

	# A command's result: stdout either way.
	result! : Output.Mode, Str, Str => Try({}, _)
	result! = |mode, human, machine|
		match mode {
			Human => Stdout.line!(human)
			Json => Stdout.line!(machine)
		}

	# Progress or a note: stderr for people, an event on stdout for machines.
	note! : Output.Mode, Str, Str => Try({}, _)
	note! = |mode, human, machine|
		match mode {
			Human => Stderr.line!(human)
			Json => Stdout.line!(machine)
		}

	# An event only machines need.
	json! : Output.Mode, Str => Try({}, _)
	json! = |mode, machine|
		match mode {
			Human => Ok({})
			Json => Stdout.line!(machine)
		}

	# A tag's name in snake case, from how Str.inspect shows the value.
	kind : Str -> Str
	kind = |inspected| {
		name = (inspected.split_on("(").first() ?? inspected).to_utf8()
		upper = |b| b >= 'A' and b <= 'Z'
		var $bytes = []
		var $lower = Bool.False
		for b in name {
			if upper(b) and $lower {
				$bytes = $bytes.append('_')
			}
			$bytes = $bytes.append(if upper(b) b + 32 else b)
			$lower = !upper(b)
		}
		Str.from_utf8_lossy($bytes)
	}

	error : Str, Str, I32 -> Str
	error = |inspected, message, exit_code|
		Output.event(
			"error",
			message,
			[
				("error", LockJson.String(Output.kind(inspected))),
				("exit_code", Output.number(exit_code)),
			],
		)

	# One workflow step, numbered from 1, with what it runs.
	step : Str,
	U64,
	U64,
	[Generate, Shell(Str), Run(Str), Build(Str)] -> {
		human : Str,
		started : Str,
		finished : Str,
	}
	step = |workflow, index, count, action| {
		(verb, name) = match action {
			Run(task) => ("run", task)
			Build(artifact) => ("build", artifact)
			Shell(shell) => ("shell", shell)
			Generate => ("generate", "")
		}
		position = "${index.to_str()}/${count.to_str()}"
		what = "${verb} ${name}"
		fields = [
			("workflow", LockJson.String(workflow)),
			("step", LockJson.Number(index.to_str())),
			("steps", LockJson.Number(count.to_str())),
			("action", LockJson.String(verb)),
			("name", LockJson.String(name)),
		]
		{
			human: "kai: workflow ${workflow} step ${position}: ${what}",
			started: Output.event("step_started", "${position} ${what}", fields),
			finished: Output.event("step_finished", "${position} ${what}", fields),
		}
	}
}

decoded = |line|
	match LockJson.decode(line) {
		Ok(Object(fields)) => fields.map(|f| (f.name, f.value))
		_ => []
	}

# Strings are escaped so every event is one valid JSON line: quotes,
# backslashes and control characters are escaped, other text is kept.
expect {
	message = "say \"hi\"\\ \n\t\u(001b)[31m é 😀"
	line = Output.event("note", message, [("path", Output.text("/p/a b"))])
	decoded(line)
		== [
			("type", LockJson.String("note")),
			("message", LockJson.String(message)),
			("path", LockJson.String("/p/a b")),
		]
		and !line.contains("\n")
			and !line.contains("\u(001b)")
				and line.contains("é 😀")
}

# Errors carry a stable kind, the readable message and kai's exit code.
expect {
	line = Output.error("ChildExited(Run(\"t\"), 7)", "task t exited", 7)
	line
		== "{\"type\":\"error\",\"message\":\"task t exited\",".concat(
			"\"error\":\"child_exited\",\"exit_code\":7}",
		)
}

# Error kinds are snake case, including acronyms and payload-free tags.
expect [
	("ChildExited(Run(\"x\"), 7.0)", "child_exited"),
	("UnsupportedHost", "unsupported_host"),
	("IO(NotFound)", "io"),
	("BadIr(Bad)", "bad_ir"),
	("InvalidUsage", "invalid_usage"),
].all(|(inspected, expected)| Output.kind(inspected) == expected)

# Workflow steps say which step of how many runs what, for both audiences.
expect {
	planned = Output.step("ci", 2, 3, Build("app"))
	planned.human == "kai: workflow ci step 2/3: build app"
		and decoded(planned.started)
			== [
				("type", LockJson.String("step_started")),
				("message", LockJson.String("2/3 build app")),
				("workflow", LockJson.String("ci")),
				("step", LockJson.Number("2")),
				("steps", LockJson.Number("3")),
				("action", LockJson.String("build")),
				("name", LockJson.String("app")),
			]
			and planned.finished.starts_with("{\"type\":\"step_finished\"")
}
