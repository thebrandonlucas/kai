# std's settings are today's Kaifile settings. std declares kai's standard
# commands (shell, run, build, workflow, update, model), the nix and guix
# backends, and implementations planning from the settings' Kaifile model.
import pf.Backend
import pf.Command
import Config
import pf.Implementation
import pf.Kaifile
import pf.Layout
import ConfigToModel
import pf.Plan
import pf.Plugin
import model.Model
import model.Project
import model.Request
import pf.LockFile
import nix.Locks
import nix.NixBackend
import guix.GuixBackend
import Pages

Std := [].{

	## The usual Kaifile.roc: std alone.
	kaifile : List(Config.Setting) -> Kaifile
	kaifile = |settings| Kaifile.new([Std.plugin(settings)])

	## Invalid settings become the plugin's problems, so Kaifile.roc fails
	## to compile.
	plugin : List(Config.Setting) -> Plugin
	plugin = |settings|
		match Std.checked_model(settings) {
			Ok(model) =>
				Plugin.new({
					name: "std",
					version: "",
					describe: model.to_str(),
					commands: Std.commands(model),
					backends: [
						Backend.{
							id: "nix",
							summary: "Nix flakes",
							program: "nix",
							flag: DoubleDashVersion,
						},
						Backend.{
							id: "guix",
							summary: "Guix shells",
							program: "guix",
							flag: DoubleDashVersion,
						},
					],
					implementations: Std.implementations(model),
				})
			Err(problem) => Plugin.invalid("std", [problem])
		}

	## The settings' model, with Raw checked too so kai check reports a Raw no
	## backend accepts instead of kai update or kai shell failing later.
	checked_model : List(Config.Setting) -> Try(Model, Str)
	checked_model = |settings| {
		model = ConfigToModel.convert(settings)?
		for raw in model.raw {
			if raw.backend != "nix" {
				return Err("unknown raw backend \"${raw.backend}\"; expected \"nix\"")
			}
		}
		_ = NixBackend.raw_values(model)?
		Ok(model)
	}

	commands : Model -> List(Command)
	commands = |model| {
		choice = |value, summary| { value, summary, details: [] }
		command = |name, page, args, lock|
			Command.{ name, summary: page.description, help: page, args, lock }
		[
			command(
				"shell",
				Pages.shell,
				[
					Name({
						name: "shell",
						help: "The shell to enter (default: default).",
						choices: model.shells.map(
							|s| choice(s.name, "Environment ${s.environment}"),
						),
						default: Default("default"),
					}),
					Trailing({
						name: "command",
						help: "A command to run inside the shell; put it after --.",
					}),
				],
				ReadsLock,
			),
			command(
				"run",
				Pages.run,
				[
					Name({
						name: "task",
						help: "The task to run.",
						choices: model.tasks.map(
							|t| choice(t.name, "${Str.join_with(t.run, " ")} [${t.environment}]"),
						),
						default: Required,
					}),
					Trailing({
						name: "args",
						help: "Arguments appended to the task's command; put them after --.",
					}),
				],
				ReadsLock,
			),
			command(
				"build",
				Pages.build,
				[
					Name({
						name: "name",
						help: "The build to run.",
						choices: model.builds.map(
							|b| choice(b.name, "Output ${b.output} [${b.environment}]"),
						),
						default: Required,
					}),
					Flag({
						name: "print-build-logs",
						short: "L",
						help: "Show the build's log as it runs.",
					}),
					Path({
						name: "out-link",
						short: "",
						help: "Link PATH to the artifact, keeping it from garbage collection.",
					}),
				],
				ReadsLock,
			),
			command(
				"workflow",
				Pages.workflow,
				[
					Name({
						name: "name",
						help: "The workflow to run.",
						choices: model.workflows.map(
							|w| choice(w.name, Str.join_with(w.steps.map(Std.step_text), ", ")),
						),
						default: Required,
					}),
				],
				ReadsLock,
			),
			command("update", Pages.update, [], OwnsLock),
			command("model", Pages.model, [], ReadsLock),
		]
	}

	step_text : Model.WorkflowStep -> Str
	step_text = |step|
		match step {
			RunTask(task, _) => "run ${task}"
			BuildArtifact(build) => "build ${build}"
			RunWorkflow(name) => "workflow ${name}"
		}

	## The model request a command's parsed arguments name.
	request : Str, Command.Args -> Try(Request, Str)
	request = |command, args|
		match command {
			"shell" => {
				command_words = Command.trailing(args, "command")
				Ok(Request.Shell(Command.name(args, "shell"), command_words))
			}
			"run" =>
				Ok(Request.Run(Command.name(args, "task"), Command.trailing(args, "args")))
			"build" => {
				shown = {
					print_build_logs: Command.flag(args, "print-build-logs"),
					out_link: Command.path(args, "out-link"),
				}
				Ok(Request.Build(Command.name(args, "name"), shown))
			}
			"workflow" => Ok(Request.Workflow(Command.name(args, "name")))
			_ => Err("std has no ${command} request")
		}

	implementations : Model -> List(Implementation)
	implementations = |model| {
		atomic = ["shell", "run", "build", "workflow"]
		nix = atomic.map(
			|command|
				Implementation.{
					command,
					backend: On("nix"),
					fit: |args| Std.fit_nix(model, Std.request(command, args)?),
					plan: |ctx| Std.plan_nix(model, Std.request(command, ctx.args)?, ctx),
				},
		)
		guix = atomic.map(
			|command|
				Implementation.{
					command,
					backend: On("guix"),
					fit: |args| GuixBackend.fit(model, Std.request(command, args)?),
					plan: |ctx| {
						GuixBackend.check_system(ctx.host.system)?
						wanted = Std.request(command, ctx.args)?
						locked = Std.guix_pins(ctx)?
						GuixBackend.request_steps(model, wanted, ctx.layout, locked)
							.map_err(|message| "cannot plan the Guix ${command}: ${message}")
					},
				},
		)
		nix
			.concat(guix)
			.concat([
				Implementation.{
					command: "update",
					backend: On("nix"),
					fit: |_| Std.lockable(model),
					plan: |ctx| Std.update_nix(model, ctx),
				},
				Implementation.{
					command: "update",
					backend: On("guix"),
					fit: |_| Std.guix_lockable(model),
					plan: |ctx| Std.update_guix(model, ctx),
				},
				Implementation.{
					command: "model",
					backend: Independent,
					fit: |_| Ok({}),
					plan: |_| {
						text = Str.drop_suffix(model.to_str(), "\n")
						Ok(Plan.{ steps: [Print(text)], next: Done })
					},
				},
			])
	}

	## Whether Nix can serve the requested closure; unrelated shells, tasks
	## and builds never matter. Nix planning checks builds itself.
	fit_nix : Model, Request -> Try({}, Str)
	fit_nix = |model, wanted| {
		environment = match wanted {
			Request.Shell(name, _) =>
				model.shells.find_first(|s| s.name == name)
					.map_ok(|s| s.environment)
					.map_err(|_| "unknown shell: ${name}")?
			Request.Run(name, _) =>
				model.tasks.find_first(|t| t.name == name)
					.map_ok(|t| t.environment)
					.map_err(|_| "unknown task: ${name}")?
			_ => return Ok({})
		}
		Project.check_environment(model, Nix, environment)
	}

	## Nix plans read the lock authority; its absence is a planning failure.
	plan_nix : Model, Request, Implementation.Context -> Try(Plan, Str)
	plan_nix = |model, wanted, ctx| {
		layout = Std.nix_layout(ctx.layout)
		path = ctx.layout.lock_path
		unreadable = |why|
			"cannot read the lock file ${path}: ${why}; run `kai update`"
		rendering = |message| "cannot generate the Nix files: ${message}"
		target = ctx.host.system
		NixBackend.preflight(model, wanted, target, layout).map_err(rendering)?
		text = match ctx.lock {
			Present(contents) => contents
			Absent => return Err("no lock file at ${path}; run `kai update`")
		}
		locks = Locks.decode(text).map_err(unreadable)?
		NixBackend.plan(model, wanted, target, layout, locks).map_err(rendering)
	}

	Run : { environment : Str, argv : List(Str), what : Str }

	## Plan `argv` inside std environment `environment` from the locked Nix
	## inputs, as a task would run: how a plugin runs a tool the project
	## declares. `what` names the step in progress and errors.
	run_in : List(Config.Setting), Implementation.Context, Run -> Try(Plan, Str)
	run_in = |settings, ctx, { environment, argv, what }| {
		model = ConfigToModel.convert(settings)?
		task = "_kai_plugin_run"
		with_task = Model.{
			format: model.format,
			name: model.name,
			requires_: model.requires_,
			systems: model.systems,
			sources: model.sources,
			inputs: model.inputs,
			environments: model.environments,
			shells: model.shells,
			tasks: model.tasks.append({ name: task, environment, run: argv }),
			build_sources: model.build_sources,
			builds: model.builds,
			workflows: model.workflows,
			extensions: model.extensions,
			raw: model.raw,
		}
		planned = Std.plan_nix(with_task, Request.Run(task, []), ctx)?
		named = |step|
			match step {
				Run(run) => Run({ ..run, what })
				other => other
			}
		Ok(Plan.{ steps: planned.steps.map(named), next: planned.next })
	}

	## Nix's generated files live in their own directory beneath kai's
	## generated root; Guix's beside them.
	nix_layout : Layout -> Layout
	nix_layout = |layout|
		Layout.{
			project_root: layout.project_root,
			workspace: layout.workspace,
			generated_root: "${layout.generated_root}/nix",
			lock_path: layout.lock_path,
		}

	## The Guix pins in the lock, or why they are missing or stale.
	guix_pins : Implementation.Context -> Try(GuixBackend.Locked, Str)
	guix_pins = |ctx| {
		missing = "the guix lock is missing or stale; run kai --backend guix update"
		section = match ctx.lock {
			Present(text) =>
				match LockFile.section(text, "guix")? {
					Present(found) => found
					Absent => return Err(missing)
				}
			Absent => return Err(missing)
		}
		GuixBackend.read_lock(section)
	}

	## Guix has something to lock when any environment can run on it.
	guix_lockable : Model -> Try({}, Str)
	guix_lockable = |model| {
		guix = |e| Project.check_environment(model, Guix, e.name).is_ok()
		if model.environments.any(guix) {
			Ok({})
		} else {
			Err("no environment can run on Guix")
		}
	}

	## Phase 0 resolves the channels and hashes the path: sources with the
	## installed `guix repl` and asks kai for the result; phase 1 validates it
	## and publishes the lock's guix section, keeping the others.
	update_guix : Model, Implementation.Context -> Try(Plan, Str)
	update_guix = |model, ctx| {
		GuixBackend.check_system(ctx.host.system)?
		dir = "${ctx.layout.generated_root}/guix"
		result = "${dir}/lock-result.json"
		channels = [GuixBackend.default_channel]
		trees = GuixBackend.source_trees(model)
		match ctx.phase {
			0 => {
				unpinned = "${dir}/channels-unpinned.scm"
				script = "${dir}/lock.scm"
				entries = channels.map(|channel| { channel, commit: Unpinned })
				# The empty result keeps a stale one from being observed.
				files = [
					{ path: unpinned, contents: GuixBackend.channels_scm(entries) },
					{ path: script, contents: GuixBackend.lock_script },
					{ path: result, contents: "" },
				]
				path = |t| "${ctx.layout.project_root}/${t.path}"
				argv = ["guix", "repl", "-q", "--", script, result, unpinned]
					.concat(trees.join_map(|t| [t.name, path(t)]))
				lock = Run({ what: "guix lock", argv, output: Inherit })
				Ok(
					Plan.{
						steps: trees.map(|t| CheckSource(path(t))).concat([Write(files), lock]),
						next: Observe([result]),
					},
				)
			}
			_ => {
				text = match ctx.observed.find_first(|o| o.path == result) {
					Ok({ contents: Text(found), .. }) => found
					_ => return Err("Guix produced no ${result}")
				}
				pinned = GuixBackend.pins(channels, text)?
				hashed = GuixBackend.hashes(trees, text)?
				locked = GuixBackend.section(pinned, hashed)
				contents = LockFile.splice(ctx.lock, "guix", locked)?
				publish = PublishLock({ previous: ctx.lock, contents })
				Ok(Plan.{ steps: [publish], next: Done })
			}
		}
	}

	## Nix has nothing to lock in a project using only Guix sources.
	lockable : Model -> Try({}, Str)
	lockable = |model| {
		used = model.environments.join_map(|e| e.tools.map(|t| t.source))
		guix = |name|
			model.sources.any(
				|s|
					s.name == name
						and match s.provider {
							GuixPackages(_) => Bool.True
							_ => Bool.False
						},
			)
		if !used.is_empty() and used.all(guix) {
			Err("every tool comes from a Guix source; Nix has nothing to lock")
		} else {
			Ok({})
		}
	}

	## Phase 0 resolves the inputs with Nix and asks kai for the result;
	## phase 1 validates it and publishes the lock.
	update_nix : Model, Implementation.Context -> Try(Plan, Str)
	update_nix = |model, ctx| {
		layout = Std.nix_layout(ctx.layout)
		target = ctx.host.system
		backend_lock = "${layout.generated_root}/flake.lock"
		match ctx.phase {
			0 => {
				files = NixBackend.update_files(model, target, layout)?
				locals = NixBackend.local_checks(model, target, layout)?
				# Replacing a stale lock by rename, rather than letting Nix follow
				# a hard-link alias, before resolving a fresh input graph.
				empty = "{\"nodes\":{\"root\":{}},\"root\":\"root\",\"version\":7}\n"
				Ok(
					Plan.{
						steps: locals
							.map(|local| CheckSource(local))
							.append(Write(files.append({ path: backend_lock, contents: empty })))
							.append(
								Run({
									what: "nix flake update",
									argv: [
										"nix",
										"flake",
										"update",
										"--flake",
										"path:${layout.generated_root}",
									],
									output: Inherit,
								}),
							),
						next: Observe([backend_lock]),
					},
				)
			}
			_ => {
				resolved = match ctx.observed.find_first(|o| o.path == backend_lock) {
					Ok({ contents: Text(text), .. }) => text
					_ => return Err("Nix produced no ${backend_lock}")
				}
				locks = Locks.from_nix(model, layout, resolved)
					.map_err(|message| "cannot lock the Nix inputs: ${message}")?
				# Other backends' sections are kept as they are.
				contents = LockFile.splice(ctx.lock, "nix", Locks.section(locks))?
				publish = PublishLock({ previous: ctx.lock, contents })
				Ok(Plan.{ steps: [publish], next: Done })
			}
		}
	}
}

# Valid settings describe the project; invalid ones name std's problem.
expect {
	valid = Kaifile.validate(Std.kaifile([Name("x")]))
	valid.map_ok(|model| model.contains("(name \"x\")")) == Ok(Bool.True)
		and Kaifile.validate(Std.kaifile([]))
			== Err("std: MissingName: declare Name once")
}

import "backends/nix/tests/local.nix-lock.json" as native_lock : Str

# A shell, task, build and workflow on one environment both backends serve;
# the unused build source matches the Nix lock fixture.
planning : List(Config.Setting)
planning = [
	Name("planning"),
	Systems(["x86_64-linux"]),
	Source("assets", "path:./assets"),
	Environment("dev", [Tools(["hello"])]),
	Shell("default", [Use("dev")]),
	Task("greet", [Use("dev"), Run(["hello", "-g", "hi"])]),
	Build("app", [Use("dev"), Run(["make"]), Output("out")]),
	Workflow("ci", [RunTask("greet", []), BuildArtifact("app")]),
]

context : Implementation.Context
context = {
	args: [],
	backend: "nix",
	host: { system: "x86_64-linux" },
	layout: Layout.{
		project_root: "/project",
		workspace: "/work",
		generated_root: "/generated",
		lock_path: "/authority/inputs.lock",
	},
	lock: Absent,
	phase: 0,
	observed: [],
}

# The planning settings' plan for `command` on the context's backend, once
# the implementation fits.
planned : Str, Implementation.Context -> Try(Plan, Str)
planned = |command, ctx| {
	model = ConfigToModel.convert(planning)?
	backends = [On(ctx.backend), Independent]
	found = Std.implementations(model)
		.find_first(|i| i.command == command and backends.contains(i.backend))
		.map_err(|_| "std has no ${command} on ${ctx.backend}")?
	(found.fit)(ctx.args)?
	(found.plan)(ctx)
}

named : Str -> Command.Args
named = |name| [{ name: "name", value: Present(name) }]

in_shell : Str -> Command.Args
in_shell = |name| [{ name: "shell", value: Present(name) }]

runs : Try(Plan, Str) -> Try(List({ what : Str, argv : List(Str) }), Str)
runs = |result|
	result.map_ok(
		|plan|
			plan.steps.keep_oks(
				|step|
					match step {
						Run({ what, argv, .. }) => Ok({ what, argv })
						_ => Err({})
					},
			),
	)

stages : Try(Plan, Str) -> Try(List(Str), Str)
stages = |result|
	result.map_ok(
		|plan|
			plan.steps.keep_oks(
				|step|
					match step {
						Stage(name) => Ok(name)
						_ => Err({})
					},
			),
	)

# The lock a phase 1 update publishes from what phase 0 observed.
published : Implementation.Context, Str, Str -> [Absent, Present(Str)]
published = |ctx, path, text| {
	resumed = { ..ctx, phase: 1, observed: [{ path, contents: Text(text) }] }
	match planned("update", resumed).map_ok(|plan| plan.steps) {
		Ok([PublishLock({ contents, .. })]) => Present(contents)
		_ => Absent
	}
}

nix_lock = published(context, "/generated/nix/flake.lock", native_lock)

guix = { ..context, backend: "guix" }

pin = "0123456789abcdef0123456789abcdef01234567"

assets_hash = "0123456789abcdfghijklmnpqrsvwxyz0123456789abcdfghijk"

guix_lock = published(
	guix,
	"/generated/guix/lock-result.json",
	"{\"channels\":[{\"name\":\"guix\",\"commit\":\"${pin}\"}],"
		.concat("\"sources\":[{\"name\":\"assets\",\"hash\":\"${assets_hash}\"}]}"),
)

develop = [
	"nix",
	"develop",
	"--no-update-lock-file",
	"--no-write-lock-file",
]

time_machine = ["guix", "time-machine", "-C", "/generated/guix/channels.scm"]

# Nix update resolves the generated flake, then publishes the observed lock
# as the lock's Nix section.
expect {
	argv = ["nix", "flake", "update", "--flake", "path:/generated/nix"]
	match nix_lock {
		Present(text) =>
			runs(planned("update", context)) == Ok([{ what: "nix flake update", argv }])
				and Locks.decode(text).is_ok()
		Absent => Bool.False
	}
}

# Guix update resolves the channels with guix repl, then publishes the
# observed pins as the lock's Guix section.
expect {
	dir = "/generated/guix"
	script = ["${dir}/lock.scm", "${dir}/lock-result.json"]
	argv = ["guix", "repl", "-q", "--"]
		.concat(script)
		.append("${dir}/channels-unpinned.scm")
		.concat(["assets", "/project/assets"])
	runs(planned("update", guix)) == Ok([{ what: "guix lock", argv }])
		and Std.guix_pins({ ..guix, lock: guix_lock })
			== Ok({
				channels: [{ channel: GuixBackend.default_channel, commit: pin }],
				sources: [{ name: "assets", path: "assets", hash: assets_hash }],
			})
}

# A Nix shell enters the locked shell; an unknown shell or a missing lock is
# refused.
expect {
	shell = { ..context, args: in_shell("default"), lock: nix_lock }
	installable = "path:/generated/nix#devShells.x86_64-linux.default"
	runs(planned("shell", shell))
		== Ok([{ what: "shell default", argv: develop.append(installable) }])
		and planned("shell", { ..shell, args: in_shell("missing") })
			== Err("unknown shell: missing")
		and planned("shell", { ..shell, lock: Absent })
			== Err("no lock file at /authority/inputs.lock; run `kai update`")
}

# A Nix task runs its command and trailing arguments in its environment.
expect {
	args = [
		{ name: "task", value: Present("greet") },
		{ name: "args", value: Many(["a b"]) },
	]
	installable = "path:/generated/nix#devShells.x86_64-linux.kai-env-dev"
	argv = develop.concat([installable, "--command", "hello", "-g", "hi", "a b"])
	runs(planned("run", { ..context, args, lock: nix_lock }))
		== Ok([{ what: "task greet", argv }])
}

# A Nix build builds its package; an unknown build is refused.
expect {
	build = { ..context, args: named("app"), lock: nix_lock }
	match runs(planned("build", build)) {
		Ok([{ what, argv }]) =>
			what == "build app"
				and argv.last() == Ok("path:/generated/nix#packages.x86_64-linux.app")
				and planned("build", { ..build, args: named("missing") }).is_err()
		_ => Bool.False
	}
}

# A Nix workflow stages each step in order.
expect {
	ci = { ..context, args: named("ci"), lock: nix_lock }
	stages(planned("workflow", ci)) == Ok(["run greet", "build app"])
		and planned("workflow", { ..ci, args: named("missing") }).is_err()
}

# A Guix shell runs guix shell at the locked channels; without the Guix
# section it is refused.
expect {
	shell = { ..guix, args: in_shell("default"), lock: guix_lock }
	argv = time_machine.concat(["--", "shell", "-q", "--pure", "hello"])
	runs(planned("shell", shell)) == Ok([{ what: "shell default", argv }])
		and planned("shell", { ..shell, lock: nix_lock }).is_err()
}

# A Guix task runs its command and trailing arguments in guix shell.
expect {
	args = [
		{ name: "task", value: Present("greet") },
		{ name: "args", value: Many(["a b"]) },
	]
	command = ["--", "hello", "-g", "hi", "a b"]
	argv = time_machine.concat(["--", "shell", "-q", "--pure", "hello"])
		.concat(command)
	runs(planned("run", { ..guix, args, lock: guix_lock }))
		== Ok([{ what: "task greet", argv }])
}

# A Guix build builds its generated file at the locked channels.
expect {
	build = { ..guix, args: named("app"), lock: guix_lock }
	scm = "/generated/guix/build-app.scm"
	argv = time_machine.concat(["--", "build", "-f", scm])
	runs(planned("build", build)) == Ok([{ what: "build app", argv }])
}

# A Guix workflow stages each step in order.
expect {
	ci = { ..guix, args: named("ci"), lock: guix_lock }
	stages(planned("workflow", ci)) == Ok(["run greet", "build app"])
}

# The model command prints the model, whatever the backend.
expect {
	match planned("model", guix).map_ok(|plan| plan.steps) {
		Ok([Print(text)]) => text.contains("(name \"planning\")")
		_ => Bool.False
	}
}

# The candidates cli/Selection.roc's std test assumes: shell, run, build,
# workflow and update on each backend --backend allows, in preference
# order; model on no backend, whatever --backend says.
expect {
	context_for = |backend| {
		args: [],
		backend,
		host: { system: "x86_64-linux" },
		layout: Layout.{
			project_root: "/p",
			workspace: "/p/.kai",
			generated_root: "/p/.kai/generated",
			lock_path: "/p/.kai/lock.json",
		},
		lock: Absent,
		phase: 0,
		observed: [],
	}
	backends = |command, choice|
		match Std.kaifile([Name("x")]).candidates(command, choice, context_for) {
			Candidates({ options, .. }) => options.map(|o| o.backend)
			_ => []
		}
	["shell", "run", "build", "workflow", "update"].all(
		|command|
			backends(command, Auto) == ["nix", "guix"]
				and backends(command, Only("nix")) == ["nix"]
				and backends(command, Only("guix")) == ["guix"],
	)
		and [Auto, Only("nix"), Only("guix")].all(
			|choice| backends("model", choice) == [""],
		)
}
