# Where kai's own messages go: results to stdout, and progress and diagnostics
# to stderr. With --json, each one is instead a JSON object on its own line of
# the same stream, with its type and a readable message first; a result goes
# to stderr instead when the plan also runs a task's or shell's program, so
# stdout is only that program's. Children (tasks, shells and their commands)
# keep inheriting stdout and stderr in both modes: their bytes are the user's
# program output, which kai must neither rewrite, buffer nor detach from a
# terminal. Kai writes an event only between children, so its events stay
# whole lines.
import pf.Stderr
import pf.Stdout

import api.LockJson
import api.Plan

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

	# A plan step's result: as `result!`, except that with --json it is an event
	# on stderr when the plan also runs a program that inherits stdout.
	step_result! : Output.Mode, Bool, Str, Str => Try({}, _)
	step_result! = |mode, shares_stdout, human, machine|
		if mode == Json and shares_stdout {
			Stderr.line!(machine)
		} else {
			Output.result!(mode, human, machine)
		}

	# Progress or a note: stderr, as text for people or an event for machines.
	note! : Output.Mode, Str, Str => Try({}, _)
	note! = |mode, human, machine|
		match mode {
			Human => Stderr.line!(human)
			Json => Stderr.line!(machine)
		}

	# An event only machines need.
	json! : Output.Mode, Str => Try({}, _)
	json! = |mode, machine|
		match mode {
			Human => Ok({})
			Json => Stderr.line!(machine)
		}

	# An error with its documented code and kai's exit code, then the fix
	# when kai knows one, the names the request may have meant, and the
	# programs the machine lacks.
	error :
		{
			code : Str,
			message : Str,
			exit_code : I32,
			hint : Str,
			suggestions : List(Str),
			programs : List(Str),
		} -> Str
	error = |{ code, message, exit_code, hint, suggestions, programs }| {
		listed = |name, names|
			if names.is_empty() {
				[]
			} else {
				[(name, LockJson.Array(names.map(Output.text)))]
			}
		Output.event(
			"error",
			message,
			[("error", Output.text(code)), ("exit_code", Output.number(exit_code))]
				.concat(if (hint.is_empty()) [] else [("hint", Output.text(hint))])
				.concat(listed("suggestions", suggestions))
				.concat(listed("programs", programs)),
		)
	}

	# The workflow kai was given, and the backend serving its steps unless a
	# step names its own.
	Reported : { workflow : Str, backend : Str }

	# One workflow step, numbered from 1. Its label is what it runs: a verb,
	# then the name it acts on ("build app"); `backend` serves it.
	step :
		Reported, U64, U64, Str -> { human : Str, started : Str, finished : Str }
	step = |{ workflow, backend }, index, count, what| {
		(verb, name) = match what.split_first(" ") {
			Ok({ before, after }) => (before, after)
			Err(_) => (what, "")
		}
		position = "${index.to_str()}/${count.to_str()}"
		fields = [
			("workflow", LockJson.String(workflow)),
			("step", LockJson.Number(index.to_str())),
			("steps", LockJson.Number(count.to_str())),
			("action", LockJson.String(verb)),
			("name", LockJson.String(name)),
			("backend", LockJson.String(backend)),
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

# Errors carry their code, the readable message, kai's exit code and, when
# kai knows them, the fix, the names the request may have meant and the
# programs the machine lacks.
expect {
	error = |hint, suggestions, programs|
		Output.error({
			code: "stale_lock",
			message: "changed",
			exit_code: 1,
			hint,
			suggestions,
			programs,
		})
	error("", [], [])
		== "{\"type\":\"error\",\"message\":\"changed\",".concat(
			"\"error\":\"stale_lock\",\"exit_code\":1}",
		)
		and error("kai update", [], []).ends_with(",\"hint\":\"kai update\"}")
		and error("", ["run"], []).ends_with(",\"suggestions\":[\"run\"]}")
		and error("", [], ["zip"]).ends_with(",\"programs\":[\"zip\"]}")
}

# Workflow steps say which step of how many runs what, for both audiences.
expect {
	planned = Output.step({ workflow: "ci", backend: "nix" }, 2, 3, "build app")
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
				("backend", LockJson.String("nix")),
			]
		and planned.finished.starts_with("{\"type\":\"step_finished\"")
}
