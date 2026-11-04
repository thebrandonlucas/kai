# Shells and tasks from pinned downloads, needing no Nix or Guix: the lock's
# `direct` section holds each Fetch's SHA-256 and size per system, and plans
# ask kai to make them ready and run with them first on PATH.
#
# The no-provider design is roc-blueprint's
# (https://github.com/lukewilliamboswell/roc-blueprint), Copyright (c) 2026
# Luke Boswell and subsequent authors, under the Universal Permissive License
# (UPL), Version 1.0.
import api.Layout
import api.LockFile
import api.LockJson
import api.Plan
import model.Model
import model.Project
import model.Request

DirectBackend := [].{
	Lock : [Absent, Present(Str)]

	## What the lock holds for one file: `key` is `<fetch>/<system>`.
	Pin : { key : Str, url : Str, sha256 : Str, size : U64 }

	update_hint = "kai --backend direct update"

	builds_need_nix = "the direct backend runs shells, tasks and workflows of "
		.concat("tasks: builds need Nix, for its sandbox")

	## Whether every tool of the environment can come from a pinned download.
	check_environment : Model, Str -> Try({}, Str)
	check_environment = |model, name| {
		project = Project.validate(model)?
		environment = project.environments.find_first(|e| e.name == name)
			.map_err(|_| "unknown environment: ${name}")?
		provider = !environment.overlays.is_empty()
			or !environment.aliases.is_empty()
			or !environment.package_env.is_empty()
			or environment.rust_toolchain != None
		tools = Project.environment_tools(environment)
		foreign = Project.package_tools(tools, project.fetches)
		used = project.fetches.keep_if(
			|f| tools.any(|t| t.source == f.name),
		)
		urls = used.join_map(|f| f.files.join_map(DirectBackend.file_urls))
		if provider {
			Err("environment ${name} needs a provider; direct has only downloads")
		} else if environment.pure {
			Err("Pure needs Nix or Guix: environment ${name}")
		} else if !foreign.is_empty() {
			names = foreign.map(|t| "${t.source}#${t.name}")
			pair = Str.join_with(names, ", ")
			Err("environment ${name} has tools that are not downloads: ${pair}")
		} else if urls.all(|url| url.starts_with("https://")) {
			Ok({})
		} else {
			Err("the direct backend downloads only over HTTPS: environment ${name}")
		}
	}

	file_urls : Model.FetchFile -> List(Str)
	file_urls = |file| [file.url].concat(file.mirrors)

	## Whether direct can serve a request: a shell or a task with no Needs
	## whose environment is all downloads, or a workflow of such tasks.
	fit : Model, Request -> Try({}, Str)
	fit = |model, request|
		match request {
			Request.Shell(name, _) =>
				match model.shells.find_first(|s| s.name == name) {
					Ok(shell) => DirectBackend.check_environment(model, shell.environment)
					Err(_) => Err("unknown shell: ${name}")
				}
			Request.Run(name, _) =>
				match model.tasks.find_first(|t| t.name == name) {
					Ok(task) if task.needs.is_empty() =>
						DirectBackend.check_environment(model, task.environment)
					Ok(_) => Err(DirectBackend.builds_need_nix)
					Err(_) => Err("unknown task: ${name}")
				}
			Request.Workflow(name) => {
				for step in Project.workflow_steps(model, name)? {
					match step {
						RunTask(task, args) =>
							DirectBackend.fit(model, Request.Run(task, args))?
						BuildArtifact(_) => return Err(DirectBackend.builds_need_nix)
						MayFail(_) => {}
					}
				}
				Ok({})
			}
			_ => Err(DirectBackend.builds_need_nix)
		}

	## Check the programs the machine must have, make the downloads ready,
	## and run the request with them first on PATH.
	plan : Model, Request, Str, Layout, Lock -> Try(Plan, Plan.Failure)
	plan = |model, request, system, layout, lock| {
		DirectBackend.fit(model, request).map_err(Plan.fail)?
		match request {
			Request.Workflow(workflow) =>
				return DirectBackend.workflow(model, workflow, system, layout, lock)
			_ => {}
		}
		declared = Project.validate(model).map_err(Plan.fail)?
		project = Project.for_system(declared, system)
		(name, command, own_env, description) = match request {
			Request.Shell(shell_name, argv) => {
				shell = project.shells.find_first(|s| s.name == shell_name)
				(
					shell.map_ok(|s| s.environment) ?? "",
					if (argv.is_empty()) DirectBackend.login else argv,
					[],
					"shell ${shell_name}",
				)
			}
			Request.Run(task_name, extra) => {
				found = project.tasks.find_first(|t| t.name == task_name)
				(
					found.map_ok(|t| t.environment) ?? "",
					(found.map_ok(|t| t.run) ?? []).concat(extra),
					found.map_ok(|t| t.env) ?? [],
					"task ${task_name}",
				)
			}
			_ => return Err(Plan.fail(DirectBackend.builds_need_nix))
		}
		Project.check_fetches_on(declared, [name], [], system).map_err(Plan.fail)?
		environment = project.environments.find_first(|e| e.name == name)
			.map_err(|_| Plan.fail("unknown environment: ${name}"))?
		pins = DirectBackend.pins(lock)?
		programs = environment.tools.map_try(
			|tool| DirectBackend.program(project, tool, system, pins),
		)?
		variables = Project.merge_env(
			Project.merge_env(
				[{ name: "KAI_SYSTEM", value: system }],
				environment.env,
			),
			own_env,
		)
		task = match request {
			Request.Run(task_name, _) =>
				project.tasks.find_first(|t| t.name == task_name)
			_ => Err(NotFound)
		}
		dir = task.map_ok(|t| t.dir) ?? ""
		bin = "${layout.workspace}/direct/${name}/bin"
		expected = DirectBackend.expected(name, environment.expected)
		run = Run({
			description,
			argv: Project.env_command(dir, variables).concat(command),
			output: Inherit,
			secrets: task.map_ok(|t| t.secrets) ?? [],
			removed_environment_variables: task
				.map_ok(|t| Project.other_tasks_secrets(project, t))
				?? [],
			kept_environment_variables: task
				.map_ok(|t| t.optional_environment_variables)
				?? [],
		})
		steps = expected.concat([Realise({ bin, programs }), run])
		Ok(Plan.{ steps, next: Done })
	}

	## Each task of a workflow in order, marked with Stages as on Nix.
	workflow : Model, Str, Str, Layout, Lock -> Try(Plan, Plan.Failure)
	workflow = |model, name, system, layout, lock| {
		var $steps = []
		for step in Project.workflow_steps(model, name).map_err(Plan.fail)? {
			$steps = match step {
				RunTask(task, args) => {
					run = Request.Run(task, args)
					part = DirectBackend.plan(model, run, system, layout, lock)?
					$steps.append(Stage("run ${task}")).concat(part.steps)
				}
				MayFail(count) => $steps.append(MayFail(count))
				BuildArtifact(_) => return Err(Plan.fail(DirectBackend.builds_need_nix))
			}
		}
		Ok(Plan.{ steps: $steps, next: Done })
	}

	## The shell kai was started from, which kai gives its children.
	login : List(Str)
	login = ["sh", "-c", "exec \"\${KAI_OPERATOR_SHELL:-/bin/sh}\""]

	## A step finding every program the environment expects on the machine,
	## and failing naming all that are missing, before anything is downloaded.
	expected : Str, List(Str) -> List(Plan.Step)
	expected = |environment, programs|
		if programs.is_empty() {
			[]
		} else {
			[ExpectPrograms({ description: "environment ${environment}", programs })]
		}

	## The download a tool names, by what the lock holds for this system.
	program :
		Model, Model.Tool, Str, List(Pin) -> Try(Plan.Program, Plan.Failure)
	program = |model, tool, system, locked_pins| {
		fetch = model.fetches.find_first(|f| f.name == tool.source)
			.map_err(|_| Plan.fail("no Fetch ${tool.source}"))?
		file = fetch.files.find_first(|f| f.system == system)
			.map_err(|_| Plan.fail("Fetch ${fetch.name} has no file for ${system}"))?
		key = "${fetch.name}/${system}"
		pin = locked_pins.find_first(|p| p.key == key).map_err(
			|_| {
				why = "the lock has no direct pin for ${key}"
				DirectBackend.lock_failure("missing_direct_lock", why)
			},
		)?
		if !DirectBackend.current(file, pin) {
			why = "the direct pin for ${key} does not match its Fetch"
			return Err(DirectBackend.lock_failure("stale_lock", why))
		}
		{ url, sha256, size, .. } = pin
		urls = [url].concat(file.mirrors)
		Ok({ name: tool.name, urls, sha256, size, unpack: file.unpack })
	}

	## A lock problem that `kai --backend direct update` fixes.
	lock_failure : Str, Str -> Plan.Failure
	lock_failure = |code, message|
		{ code, message, hint: DirectBackend.update_hint, suggestions: [] }

	## Whether a pin is for this URL and, if the Fetch publishes a sha256, for
	## that one.
	current : Model.FetchFile, Pin -> Bool
	current = |file, pin|
		pin.url == file.url
			and (file.hash.is_empty() or Project.sri_sha256(pin.sha256) == Ok(file.hash))

	## The pins of the lock's `direct` section.
	pins : Lock -> Try(List(Pin), Plan.Failure)
	pins = |lock| {
		text = match lock {
			Present(found) => found
			Absent => return Ok([])
		}
		section = match LockFile.section(text, "direct").map_err(Plan.fail)? {
			Present(found) => found
			Absent => return Ok([])
		}
		DirectBackend.read(section).map_err(
			|why| DirectBackend.lock_failure("invalid_lock", why),
		)
	}

	read : LockJson -> Try(List(Pin), Str)
	read = |section|
		LockJson.array(LockJson.field(section, "files")?)?.map_try(
			|entry| {
				text = |name| LockJson.string(LockJson.field(entry, name)?)
				size = match LockJson.field(entry, "size")? {
					Number(digits) => U64.from_str(digits).map_err(|_| "invalid size")?
					_ => return Err("invalid size")
				}
				Ok({
					key: text("key")?,
					url: text("url")?,
					sha256: text("sha256")?,
					size,
				})
			},
		)

	section : List(Pin) -> LockJson
	section = |entries| {
		entry = |{ key, url, sha256, size }|
			Object([
				{ name: "key", value: String(key) },
				{ name: "sha256", value: String(sha256) },
				{ name: "size", value: Number(size.to_str()) },
				{ name: "url", value: String(url) },
			])
		Object([{ name: "files", value: Array(entries.map(entry)) }])
	}

	## Every file of every Fetch, with the key the lock holds it under.
	files : Model -> List({ fetch : Str, key : Str, file : Model.FetchFile })
	files = |model|
		model.fetches.join_map(
			|{ name, files: fetched, .. }|
				fetched.map(|file| { fetch: name, key: "${name}/${file.system}", file }),
		)

	## Phase 0 asks kai to measure every file the lock has no current pin
	## for, and every file of the Fetches `names` lists, so a file already
	## pinned is not fetched or changed unless named; phase 1 checks what kai
	## measured and publishes the section, keeping the others.
	update :
		Model, List(Str), Layout, Lock, U64, List(Observed) -> Try(Plan, Plan.Failure)
	update = |model, names, layout, lock, phase, observed| {
		result = "${layout.generated_root}/direct/measured"
		kept = DirectBackend.pins(lock)?
		pinned = |{ fetch, key, file }|
			!names.contains(fetch)
				and kept.any(|p| p.key == key and DirectBackend.current(file, p))
		wanted = DirectBackend.files(model)
		if phase == 0 {
			measured = wanted.drop_if(pinned).map(
				|{ key, file, .. }| { key, urls: DirectBackend.file_urls(file) },
			)
			return Ok(
				Plan.{
					steps: [Measure({ files: measured, result })],
					next: Observe([result]),
				},
			)
		}
		text = match observed.find_first(|o| o.path == result) {
			Ok({ contents: Text(found), .. }) => found
			_ => return Err(Plan.fail("kai measured nothing at ${result}"))
		}
		fresh = text.split_on("\n").keep_oks(
			|line|
				match line.split_on(" ") {
					[key, sha256, size] =>
						Ok({ key, sha256, size: U64.from_str(size) ?? 0 })
					_ => Err({})
				},
		)
		next = wanted.map_try(
			|{ key, file, .. }|
				match fresh.find_first(|f| f.key == key) {
					Ok({ sha256, size, .. }) => {
						pin = { key, url: file.url, sha256, size }
						if (DirectBackend.current(file, pin))
							Ok(pin)
						else
							Err(Plan.fail("${key} is not the file its sha256 publishes"))
					}
					Err(_) =>
						kept.find_first(|p| p.key == key)
							.map_err(|_| Plan.fail("kai did not measure ${key}"))
				},
		)?
		contents = LockFile.splice(lock, "direct", DirectBackend.section(next))
			.map_err(Plan.fail)?
		Ok(Plan.{ steps: [PublishLock({ previous: lock, contents })], next: Done })
	}

	Observed : { path : Str, contents : [Missing, Text(Str)] }
}

layout : Layout
layout = Layout.{
	project_root: "/p",
	workspace: "/p/.kai",
	generated_root: "/p/.kai/generated",
	lock_path: "/p/.kai/lock.json",
}

sha256 = "ab".repeat(32)

archive : Model.FetchFile
archive = {
	system: "x86_64-linux",
	url: "https://example.com/tool.tar.xz",
	hash: "",
	mirrors: ["https://mirror.example/tool.tar.xz"],
	unpack: Archive("tool-1/tool"),
}

published : Model.FetchFile
published = {
	system: "x86_64-linux",
	url: "https://example.com/other",
	hash: Project.sri_sha256(sha256) ?? "",
	mirrors: [],
	unpack: File,
}

environment : Model.Environment
environment = {
	name: "dev",
	parents: [],
	tools: [{ source: "tool", name: "tool" }, { source: "other", name: "other" }],
	overlays: [],
	env: [{ name: "A", value: "1" }],
	pure: Bool.False,
	aliases: [],
	rust_toolchain: None,
	package_env: [],
	on_systems: [],
	expected: ["git", "gh"],
}

task : Model.Task
task = {
	name: "t",
	environment: "dev",
	run: ["tool", "--flag"],
	env: [],
	secrets: ["TOKEN"],
	optional_environment_variables: [],
	needs: [],
	description: "",
	dir: "",
}

model : Model
model = {
	..Model.empty("direct tests"),
	requires_: ["fetches", "fetch_locked", "expect", "secrets", "workflows"],
	systems: ["x86_64-linux"],
	environments: [environment],
	fetches: [
		{ name: "tool", files: [archive], unavailable: [] },
		{ name: "other", files: [published], unavailable: [] },
	],
	shells: [{ name: "default", environment: "dev", description: "" }],
	tasks: [task],
	workflows: [{ name: "ci", description: "", steps: [RunTask("t", ["x"])] }],
}

pin = |key, url| { key, url, sha256, size: 3 }

both = [
	pin("tool/x86_64-linux", archive.url),
	pin("other/x86_64-linux", published.url),
]

locked = |pins|
	Present(LockFile.splice(Absent, "direct", DirectBackend.section(pins)) ?? "")

planned = |request, lock|
	DirectBackend.plan(model, request, "x86_64-linux", layout, lock)

code = |result|
	match result {
		Ok(_) => ""
		Err(failure) => failure.code
	}

# A task checks what the machine must have, makes its downloads ready, then
# runs in its environment with its secrets; the pins survive the lock.
expect {
	request = Request.Run("t", ["x"])
	match planned(request, locked(both)).map_ok(|p| p.steps) {
		Ok([ExpectPrograms(check), Realise({ bin, programs }), Run(run)]) =>
			check == { description: "environment dev", programs: ["git", "gh"] }
				and bin == "/p/.kai/direct/dev/bin"
				and programs.map(|p| (p.name, p.urls, p.unpack)) == [
					("tool", [archive.url].concat(archive.mirrors), archive.unpack),
					("other", [published.url], File),
				]
				and programs.all(|p| p.sha256 == sha256 and p.size == 3)
				and run.argv == ["env", "KAI_SYSTEM=x86_64-linux", "A=1"]
					.concat(["tool", "--flag", "x"])
				and run.secrets == ["TOKEN"]
		_ => Bool.False
	}
}

# A shell with no command starts the operator's shell; one with a command
# runs it.
expect {
	argv = |command|
		match planned(Request.Shell("default", command), locked(both)) {
			Ok(found) =>
				match found.steps.last() {
					Ok(Run(run)) => run.argv.drop_first(3)
					_ => []
				}
			Err(_) => []
		}
	argv([]) == DirectBackend.login
		and argv(["zig", "version"]) == ["zig", "version"]
}

# The lock must hold a current pin for each download.
expect {
	request = Request.Run("t", [])
	moved = [
		pin("tool/x86_64-linux", "https://example.com/old"),
		pin("other/x86_64-linux", published.url),
	]
	wrong = [
		pin("tool/x86_64-linux", archive.url),
		{ ..pin("other/x86_64-linux", published.url), sha256: "cd".repeat(32) },
	]
	code(planned(request, Absent)) == "missing_direct_lock"
		and code(planned(request, locked(both.drop_first(1))))
			== "missing_direct_lock"
		and code(planned(request, locked(moved))) == "stale_lock"
		and code(planned(request, locked(wrong))) == "stale_lock"
}

# Only environments made of downloads fit, and builds refuse saying they need
# Nix.
expect {
	changed_to = |changed| { ..model, environments: [changed] }
	refused = [
		{ ..environment, overlays: ["x"] },
		{ ..environment, pure: Bool.True },
		{ ..environment, tools: [{ source: "default", name: "hello" }] },
	]
	shell = Request.Shell("default", [])
	DirectBackend.fit(model, shell) == Ok({})
		and refused.all(|e| DirectBackend.fit(changed_to(e), shell).is_err())
		and DirectBackend.fit(model, Request.build("app"))
			== Err(DirectBackend.builds_need_nix)
}

# Update measures only what the lock lacks, then publishes what kai measured.
expect {
	result = "/p/.kai/generated/direct/measured"
	lock = locked(both.drop_first(1))
	asked = match DirectBackend.update(model, [], layout, lock, 0, []) {
		Ok(first) => first.steps
		Err(_) => []
	}
	line = "tool/x86_64-linux ${"cd".repeat(32)} 9\n"
	observed = [{ path: result, contents: Text(line) }]
	publishing = DirectBackend.update(model, [], layout, lock, 1, observed)
	match (asked, publishing.map_ok(|p| p.steps)) {
		(
			[Measure({ files: [{ key, urls }], .. })],
			Ok([PublishLock({ contents, .. })]),
		) =>
			key == "tool/x86_64-linux"
				and urls == [archive.url].concat(archive.mirrors)
				and DirectBackend.pins(Present(contents))
					.map_ok(|found| found.map(|p| (p.key, p.size)))
					== Ok([("tool/x86_64-linux", 9), ("other/x86_64-linux", 3)])
		_ => Bool.False
	}
}

# A workflow of tasks stages each task's steps in order.
expect {
	steps = planned(Request.Workflow("ci"), locked(both)).map_ok(|p| p.steps)
	task_steps = planned(Request.Run("t", ["x"]), locked(both)).map_ok(|p| p.steps)
	steps == task_steps.map_ok(|found| [Stage("run t")].concat(found))
}

# Naming a Fetch measures its files again, even when they are pinned.
expect {
	match DirectBackend.update(model, ["other"], layout, locked(both), 0, []) {
		Ok({ steps: [Measure({ files, .. })], .. }) =>
			files.map(|f| f.key) == ["other/x86_64-linux"]
		_ => Bool.False
	}
}

# A file that is not the one its Fetch publishes is not locked.
expect {
	result = "/p/.kai/generated/direct/measured"
	line = "other/x86_64-linux ${"cd".repeat(32)} 9\n"
	observed = [{ path: result, contents: Text(line) }]
	lock = locked(both.drop_last(1))
	DirectBackend.update(model, [], layout, lock, 1, observed).is_err()
}
