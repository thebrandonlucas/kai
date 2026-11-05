# std's settings are today's Kaifile settings. std declares kai's standard
# commands (shell, run, build, workflow, update, model, spec, lock), the nix
# and direct backends, and implementations planning from the settings'
# Kaifile model.
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
import direct.DirectBackend
import LockReport
import Pages
import Spec
import StdModel

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
							id: "direct",
							summary: "Pinned downloads, with no provider",
							program: "",
							flag: DoubleDashVersion,
						},
					],
					implementations: Std.implementations(model),
				})
			Err(problem) => Plugin.invalid("std", [problem])
		}

	## The settings' model, with Systems and Raw checked too so kai check
	## reports what no backend accepts instead of every command failing later.
	checked_model : List(Config.Setting) -> Try(Model, Str)
	checked_model = |settings| {
		model = ConfigToModel.convert(settings)?
		nix_systems = NixBackend.supported_systems
		for system in model.systems {
			if DirectBackend.only_systems.contains(system) {
				DirectBackend.check_system(model, system)?
			} else if !nix_systems.contains(system) {
				return Err(
					"unsupported system ${system}; Nix supports "
						.concat("${Str.join_with(nix_systems, ", ")} and ")
						.concat("direct also ${Str.join_with(DirectBackend.only_systems, ", ")}"),
				)
			}
		}
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
		# A declaration's Description, if any, replaces its summary in lists;
		# its own page, such as `kai run test --help`, shows both.
		choice = |value, description, summary|
			if description.is_empty() {
				{ value, summary, details: [] }
			} else {
				{ value, summary: description, details: [summary] }
			}
		default_build = model.builds.find_first(|b| b.default)
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
							|s| choice(s.name, s.description, "Environment ${s.environment}"),
						),
						default: Default("default"),
					}),
					Trailing({
						name: "command",
						help: "A command to run inside the shell; put it after --.",
						choices: [],
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
							|t| choice(
								t.name,
								t.description,
								"${Str.join_with(t.run, " ")} [${t.environment}]",
							),
						),
						default: Required,
					}),
					Trailing({
						name: "args",
						help: "Arguments appended to the task's command; put them after --.",
						choices: [],
					}),
				],
				ReadsLock,
			),
			command(
				"build",
				Pages.build,
				[
					Name({
						name: "build",
						help: match default_build {
							Ok(build) => "The build to run (default: ${build.name})."
							Err(_) => "The build to run."
						},
						choices: model.builds.map(
							|b| choice(
								b.name,
								b.description,
								"Output ${b.output} [${b.environment}]",
							),
						),
						default: match default_build {
							Ok(build) => Default(build.name)
							Err(_) => Required
						},
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
					Flag({
						name: "plan",
						short: "",
						help: "Print the build's plan and identity as JSON instead of building.",
					}),
					Flag({
						name: "rebuild",
						short: "",
						help: "Build again and fail if the output differs from the stored one.",
					}),
				],
				ReadsLock,
			),
			command(
				"workflow",
				Pages.workflow,
				[
					Name({
						name: "workflow",
						help: "The workflow to run.",
						choices: model.workflows.map(
							|w| choice(
								w.name,
								w.description,
								Str.join_with(w.steps.map(Std.step_text), ", "),
							),
						),
						default: Required,
					}),
				],
				ReadsLock,
			),
			command(
				"update",
				Pages.update,
				[
					Trailing({
						name: "inputs",
						help: "Inputs, or FetchLocked files to measure again (default: all).",
						choices: (Locks.inputs(model) ?? [])
							.map(|input| choice(input.name, "", input.ref))
							.concat(
								model.fetches
									.keep_if(|f| Project.locked_fetch(model, f.name))
									.map(|f| choice(f.name, "", "FetchLocked")),
							)
							.concat(
								model.cargo_vendors.map(|c| choice(c.name, "", "CargoVendor")),
							),
					}),
				],
				OwnsLock,
			),
			command("model", Pages.model, [], ReadsLock),
			command("spec", Pages.spec, [], ReadsLock),
			command("lock", Pages.lock, [], ReadsLock),
		]
	}

	step_text : Model.WorkflowStep -> Str
	step_text = |step|
		match step {
			RunTask(task, _) => "run ${task}"
			BuildArtifact(build) => "build ${build}"
			RunWorkflow(name) => "workflow ${name}"
			MayFail(_) => "${Std.step_text(Project.wrapped(step))} (may fail)"
		}

	implementations : Model -> List(Implementation)
	implementations = |model| {
		atomic = ["shell", "run", "build", "workflow"]
		nix = atomic.map(
			|command|
				Implementation.{
					command,
					backend: On("nix"),
					fit: |args| Std.fit_nix(model, StdModel.request(command, args)?),
					plan: |ctx| {
						wanted = StdModel.request(command, ctx.args).map_err(Plan.fail)?
						Std.plan_nix(model, wanted, ctx)
					},
				},
		)
		direct = atomic.map(
			|command|
				Implementation.{
					command,
					backend: On("direct"),
					fit: |args| DirectBackend.fit(model, StdModel.request(command, args)?),
					plan: |ctx| {
						wanted = StdModel.request(command, ctx.args).map_err(Plan.fail)?
						StdModel.known(model, wanted)?
						{ host, layout, lock, .. } = ctx
						DirectBackend.plan(model, wanted, host.system, layout, lock)
					},
				},
		)
		nix
			.concat(direct)
			.concat([
				Implementation.{
					command: "update",
					backend: On("nix"),
					fit: |args| {
						names = Command.trailing(args, "inputs")
						if names.any(|name| Project.locked_fetch(model, name)) {
							Err("FetchLocked files are pinned by direct; name only Nix inputs")
						} else {
							Std.lockable(model)
						}
					},
					plan: |ctx| {
						Std.known_inputs(model, Command.trailing(ctx.args, "inputs"))?
						nix_model = StdModel.revised(Std.on_nix(model), ctx)
						Std.update_nix(nix_model, ctx).map_err(Plan.fail)
					},
				},
				Implementation.{
					command: "update",
					backend: On("direct"),
					fit: |args| {
						names = Command.trailing(args, "inputs")
						if !names.all(|name| Project.locked_fetch(model, name)) {
							Err("direct measures again only FetchLocked files; name only those")
						} else if model.fetches.is_empty() {
							Err("no Fetch to pin")
						} else {
							Ok({})
						}
					},
					plan: |ctx| {
						{ layout, lock, phase, observed, .. } = ctx
						names = Command.trailing(ctx.args, "inputs")
						DirectBackend.update(model, names, layout, lock, phase, observed)
					},
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
				Implementation.{
					command: "spec",
					backend: Independent,
					fit: |_| Ok({}),
					plan: |_| Ok(Plan.{ steps: [Print(Spec.json(model))], next: Done }),
				},
				Implementation.{
					command: "lock",
					backend: Independent,
					fit: |_| Ok({}),
					plan: LockReport.plan,
				},
			])
	}

	## Whether Nix can serve the requested closure, a workflow's tasks
	## included; unrelated shells, tasks and builds never matter. Nix planning
	## checks builds itself.
	fit_nix : Model, Request -> Try({}, Str)
	fit_nix = |model, wanted| {
		environment = match wanted {
			Request.Workflow(name) => {
				# Planning reports an unknown workflow, with the names it may mean.
				steps = Project.workflow_steps(model, name) ?? []
				for step in steps {
					match step {
						RunTask(task, args) => Std.fit_nix(model, Request.Run(task, args))?
						_ => {}
					}
				}
				return Ok({})
			}
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
		Project.check_environment(model, environment)
	}

	## Inputs `kai update` was asked to move that the project does not declare.
	known_inputs : Model, List(Str) -> Try({}, Plan.Failure)
	known_inputs = |model, names| {
		inputs = Locks.inputs(model).map_err(Plan.fail)?.map(|input| input.name)
		declared = inputs.concat(model.cargo_vendors.map(|c| c.name))
		unknown = names.drop_if(|name| declared.contains(name))
		if unknown.is_empty() {
			Ok({})
		} else {
			message = "unknown input ${Str.join_with(unknown, ", ")}; "
				.concat("the inputs are ${Str.join_with(declared, ", ")}")
			suggestions = unknown.join_map(|name| Plan.closest(name, declared))
			Err({ code: "unknown_input", message, hint: "", suggestions })
		}
	}

	## Nix plans read the lock authority; its absence is a planning failure.
	plan_nix : Model, Request, Implementation.Context -> Try(Plan, Plan.Failure)
	plan_nix = |declared, wanted, ctx| {
		model = StdModel.revised(Std.on_nix(declared), ctx)
		layout = Std.nix_layout(ctx.layout)
		path = ctx.layout.lock_path
		lock_failure = |code, message|
			{ code, message, hint: "kai update", suggestions: [] }
		unreadable = |why|
			lock_failure("invalid_lock", "cannot read the lock file ${path}: ${why}")
		rendering = |message| Plan.fail("cannot generate the Nix files: ${message}")
		target = ctx.host.system
		StdModel.known(model, wanted)?
		NixBackend.preflight(model, wanted, target, layout).map_err(rendering)?
		text = match ctx.lock {
			Present(contents) => contents
			Absent => return Err(lock_failure("missing_lock", "no lock file at ${path}"))
		}
		if LockFile.section(text, "nix") == Ok(Absent) {
			sectionless = "the lock at ${path} has no Nix section"
			return Err(lock_failure("missing_lock", sectionless))
		}
		locks = Locks.decode(text).map_err(unreadable)?
		stale = Locks.staleness(locks, model).map_err(rendering)?
		if !stale.is_empty() {
			return Err(lock_failure("stale_lock", stale))
		}
		# As on direct, the machine's Expect programs are checked, and the
		# FetchLocked tools made ready, before a shell or task enters.
		validated = Project.validate(model).map_err(Plan.fail)?
		project = Project.for_system(validated, target)
		entering = Std.entered(model, wanted).map_try(
			|name| {
				environment = project.environments.find_first(|e| e.name == name)
					.map_err(|_| Plan.fail("unknown environment: ${name}"))?
				tools = environment.tools
					.keep_if(|t| Project.locked_fetch(project, t.source))
				downloads = { project, environment, tools }
				steps = DirectBackend.entering(downloads, target, layout, ctx.lock)?
				Ok({ environment: name, steps })
			},
		)?
		continued = { phase: ctx.phase, observed: ctx.observed }
		planned = match wanted {
			Request.Build(name, { mode: Plan, .. }) =>
				NixBackend.plan_build(model, name, target, layout, locks, continued)
			_ =>
				NixBackend.plan_entering(model, wanted, target, layout, locks, entering)
		}
		planned.map_err(rendering)
	}

	## The environments a request's shells and tasks enter.
	entered : Model, Request -> List(Str)
	entered = |model, wanted|
		match wanted {
			Request.Shell(name, _) =>
				model.shells.keep_if(|s| s.name == name).map(|s| s.environment)
			Request.Run(name, _) =>
				model.tasks.keep_if(|t| t.name == name).map(|t| t.environment)
			Request.Workflow(name) =>
				(Project.workflow_steps(model, name) ?? []).join_map(
					|step|
						match step {
							RunTask(task, args) => Std.entered(model, Request.Run(task, args))
							_ => []
						},
				)
			Request.Build(_, _) => []
		}

	Run : { environment : Str, argv : List(Str), description : Str }

	## Plan `argv` inside std environment `environment` from the locked Nix
	## inputs, as a task would run: how a plugin runs a tool the project
	## declares. `description` names the step in progress and errors.
	run_in :
		List(Config.Setting), Implementation.Context, Run -> Try(Plan, Plan.Failure)
	run_in = |settings, ctx, { environment, argv, description }| {
		model = ConfigToModel.convert(settings).map_err(Plan.fail)?
		task = "_kai_plugin_run"
		with_task = Model.{
			format: model.format,
			name: model.name,
			requires_: model.requires_,
			systems: model.systems,
			sources: model.sources,
			inputs: model.inputs,
			follows: model.follows,
			environments: model.environments,
			shells: model.shells,
			tasks: model.tasks.append({
				name: task,
				environment,
				run: argv,
				env: [],
				secrets: [],
				optional_environment_variables: [],
				needs: [],
				description: "",
				dir: "",
			}),
			build_sources: model.build_sources,
			fetches: model.fetches,
			cargo_vendors: model.cargo_vendors,
			build_root: model.build_root,
			builds: model.builds,
			workflows: model.workflows,
			extensions: model.extensions,
			raw: model.raw,
		}
		planned = Std.plan_nix(with_task, Request.Run(task, []), ctx)?
		named = |step|
			match step {
				Run(run) => Run({ ..run, description })
				other => other
			}
		Ok(Plan.{ steps: planned.steps.map(named), next: planned.next })
	}

	## The model as Nix sees it: its flake names no system only direct serves.
	on_nix : Model -> Model
	on_nix = |model| {
		..model,
		systems: model.systems.drop_if(|s| DirectBackend.only_systems.contains(s)),
	}

	## Nix's generated files live in their own directory beneath kai's
	## generated root.
	nix_layout : Layout -> Layout
	nix_layout = |layout|
		Layout.{
			project_root: layout.project_root,
			workspace: layout.workspace,
			generated_root: "${layout.generated_root}/nix",
			lock_path: layout.lock_path,
		}

	## Nix has nothing to lock in a project using only Guix sources.
	lockable : Model -> Try({}, Str)
	lockable = |model| {
		nix = model.environments.drop_if(|e| Project.direct_only(model, e))
		if nix.is_empty() and !model.environments.is_empty() {
			return Err("every environment needs the direct backend")
		}
		used = nix.join_map(|e| e.tools.map(|t| t.source))
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
				requested = Command.trailing(ctx.args, "inputs")
				# Cargo.lock, not the lock, pins a CargoVendor's crates.
				vendors = model.cargo_vendors.map(|c| c.name)
				vendored = requested.keep_if(|name| vendors.contains(name))
				names = requested.drop_if(|name| vendored.contains(name))
				notes = vendored.map(
					|name|
						Note("Cargo.lock pins CargoVendor ${name}; `cargo update` moves it"),
				)
				if names.is_empty() and !vendored.is_empty() {
					return Ok(Plan.{ steps: notes, next: Done })
				}
				# Replacing a stale lock by rename, rather than letting Nix follow
				# a hard-link alias, before resolving a fresh input graph, or the
				# locked one when only the named inputs move.
				empty = "{\"nodes\":{\"root\":{}},\"root\":\"root\",\"version\":7}\n"
				starting_lock = match ctx.lock {
					Present(text) if !names.is_empty() =>
						match LockFile.section(text, "nix")? {
							Present(_) => Locks.rebase(Locks.decode(text)?, layout)?.contents
							Absent => empty
						}
					_ => empty
				}
				Ok(
					Plan.{
						steps: notes
							.concat(locals.map(|local| CheckSource(local)))
							.append(
								Write(files.append({ path: backend_lock, contents: starting_lock })),
							)
							.append(
								Run({
									description: "nix flake update",
									argv: [
										"nix",
										"flake",
										"update",
										"--flake",
										"path:${layout.generated_root}",
									].concat(names),
									output: Quiet,
									secrets: [],
									removed_environment_variables: [],
									kept_environment_variables: [],
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
				previous = match ctx.lock {
					Present(text) => Locks.decode(text)
					Absent => Err("no lock")
				}
				changed = match Locks.changes(previous, locks) {
					[] => ["no input changed"]
					lines => lines
				}
				publish = PublishLock({ previous: ctx.lock, contents })
				steps = [publish].concat(changed.map(|line| Note(line)))
				Ok(Plan.{ steps, next: Done })
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

# A shell, task, build and workflow on one environment; the unused build
# source matches the Nix lock fixture.
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
	revision: { describe: "", commit_date: "" },
	lock: Absent,
	phase: 0,
	observed: [],
}

# The planning settings' plan for `command` on the context's backend, once
# the implementation fits.
planned : Str, Implementation.Context -> Try(Plan, Plan.Failure)
planned = |command, ctx| {
	model = ConfigToModel.convert(planning).map_err(Plan.fail)?
	backends = [On(ctx.backend), Independent]
	found = Std.implementations(model)
		.find_first(|i| i.command == command and backends.contains(i.backend))
		.map_err(|_| Plan.fail("std has no ${command} on ${ctx.backend}"))?
	(found.fit)(ctx.args).map_err(Plan.fail)?
	(found.plan)(ctx)
}

# The code a plan failed with, or "" when it did not fail.
failed : Try(Plan, Plan.Failure) -> Str
failed = |result|
	match result {
		Ok(_) => ""
		Err(failure) => failure.code
	}

named : Str, Str -> Command.Args
named = |argument, name| [{ name: argument, value: Present(name) }]

in_shell : Str -> Command.Args
in_shell = |name| [{ name: "shell", value: Present(name) }]

Ran : { description : Str, argv : List(Str) }

runs : Try(Plan, Plan.Failure) -> Try(List(Ran), Plan.Failure)
runs = |result|
	result.map_ok(
		|plan|
			plan.steps.keep_oks(
				|step|
					match step {
						Run({ description, argv, .. }) => Ok({ description, argv })
						_ => Err({})
					},
			),
	)

stages : Try(Plan, Plan.Failure) -> Try(List(Str), Plan.Failure)
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
		Ok([PublishLock({ contents, .. }), ..]) => Present(contents)
		_ => Absent
	}
}

nix_lock = published(context, "/generated/nix/flake.lock", native_lock)

develop = [
	"nix",
	"develop",
	"--no-update-lock-file",
	"--no-write-lock-file",
]

# The Nix steps that evaluate an environment before a shell or task enters it.
evaluating : Str, Str -> { description : Str, argv : List(Str) }
evaluating = |what, installable| {
	description: "evaluating the environment of ${what}",
	argv: ["nix", "eval", "--raw", "--no-update-lock-file", "--no-write-lock-file"]
		.concat([installable, "--apply", "shell: builtins.seq shell.drvPath \"\""]),
}

# Nix update resolves the generated flake, then publishes the observed lock
# as the lock's Nix section; it refuses to move an input the project lacks.
expect {
	argv = ["nix", "flake", "update", "--flake", "path:/generated/nix"]
	unknown_input = { name: "inputs", value: Many(["nope"]) }
	match nix_lock {
		Present(text) =>
			runs(planned("update", context))
				== Ok([{ description: "nix flake update", argv }])
				and Locks.decode(text).is_ok()
				and failed(planned("update", { ..context, args: [unknown_input] }))
					== "unknown_input"
		Absent => Bool.False
	}
}

# Cargo.lock pins a CargoVendor, so `kai update` accepts its name and, given
# it, only says so; other names it is given still move.
expect {
	updated = |names| {
		vendored = planning.append(CargoVendor("crates", ""))
		model = ConfigToModel.convert(vendored).map_err(Plan.fail)?
		update = Std.implementations(model)
			.find_first(|i| i.command == "update" and i.backend == On("nix"))
			.map_err(|_| Plan.fail("no update"))?
		args = [{ name: "inputs", value: Many(names) }]
		(update.plan)({ ..context, args }).map_ok(|plan| plan.steps)
	}
	note = Note("Cargo.lock pins CargoVendor crates; `cargo update` moves it")
	updated(["crates"]) == Ok([note])
		and match updated(["default", "crates"]) {
			Ok([first, .., Run({ argv, .. })]) =>
				first == note and argv.last() == Ok("default")
			_ => Bool.False
		}
}

# Help lists a task's Description, else its command, and the task's own page
# shows its command after the Description.
expect {
	described = Task("hush", [Use("dev"), Description("Quiet"), Run(["true"])])
	tasks = |model|
		Std.commands(model).find_first(|c| c.name == "run").map_ok(
			|run|
				run.args.join_map(
					|arg|
						match arg {
							Name(n) => n.choices
							_ => []
						},
				),
		)
	match ConfigToModel.convert(planning.append(described)) {
		Ok(model) => tasks(model) == Ok([
			{ value: "greet", summary: "hello -g hi [dev]", details: [] },
			{ value: "hush", summary: "Quiet", details: ["true [dev]"] },
		])
		Err(_) => Bool.False
	}
}

# A Nix shell evaluates its environment, then enters the locked shell; an
# unknown shell or a missing lock is refused.
expect {
	shell = { ..context, args: in_shell("default"), lock: nix_lock }
	installable = "path:/generated/nix#devShells.x86_64-linux.default"
	runs(planned("shell", shell))
		== Ok([
			evaluating("shell default", installable),
			{ description: "shell default", argv: develop.append(installable) },
		])
		and planned("shell", { ..shell, args: in_shell("missing") })
			== Err(Plan.fail("unknown shell: missing"))
		and planned("shell", { ..shell, lock: Absent })
			== Err({
				code: "missing_lock",
				message: "no lock file at /authority/inputs.lock",
				hint: "kai update",
				suggestions: [],
			})
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
		== Ok([
			evaluating("task greet", installable),
			{ description: "task greet", argv },
		])
}

# A Nix build builds its package; an unknown build is refused.
expect {
	build = { ..context, args: named("build", "app"), lock: nix_lock }
	match runs(planned("build", build)) {
		Ok([{ description, argv }]) =>
			description == "build app"
				and argv.last() == Ok("path:/generated/nix#packages.x86_64-linux.app")
				and failed(planned("build", { ..build, args: named("build", "missing") }))
					== "unknown_name"
		_ => Bool.False
	}
}

# A Nix workflow stages each step in order.
expect {
	ci = { ..context, args: named("workflow", "ci"), lock: nix_lock }
	stages(planned("workflow", ci)) == Ok(["run greet", "build app"])
		and failed(planned("workflow", { ..ci, args: named("workflow", "missing") }))
			== "unknown_name"
}

# The model command prints the model, whatever the backend.
expect {
	direct = { ..context, backend: "direct" }
	match planned("model", direct).map_ok(|plan| plan.steps) {
		Ok([Print(text)]) => text.contains("(name \"planning\")")
		_ => Bool.False
	}
}

# The candidates cli/Selection.roc's std test assumes: shell, run, build,
# workflow and update on each backend --backend allows, in preference
# order; model, spec and lock on no backend, whatever --backend says.
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
		revision: { describe: "", commit_date: "" },
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
			backends(command, Auto) == ["nix", "direct"]
				and backends(command, Only("nix")) == ["nix"]
				and backends(command, Only("direct")) == ["direct"],
	)
		and [Auto, Only("nix"), Only("direct")].all(
			|choice| ["model", "spec", "lock"].all(|c| backends(c, choice) == [""]),
		)
}

# On Nix, a task whose environment mixes a package tool with a FetchLocked
# download and an Expect checks the machine's programs and makes the
# download ready before it enters, and sh puts it first on PATH there; the
# lock must pin it. Direct refuses the package tool, naming it, and a build
# cannot use the environment.
expect {
	file = {
		system: "x86_64-linux",
		url: "https://example.com/t",
		mirrors: [],
		program: File,
	}
	settings = planning.concat([
		FetchLocked("tool", [file]),
		Environment("mixed", [Tools(["hello", "tool#tool"]), Expect(["git"])]),
		Task("both", [Use("mixed"), Run(["tool"])]),
	])
	sha256 = "ab".repeat(32)
	tool_pin = { key: "tool/x86_64-linux", url: file.url, sha256, size: 3 }
	section = DirectBackend.section([tool_pin])
	pinned = Present(LockFile.splice(nix_lock, "direct", section) ?? "")
	bin = "/work/direct/mixed/bin"
	entering = ["sh", "-c", "PATH=\"$0:$PATH\" && exec \"$@\"", bin, "tool"]
	built = Build("b", [Use("mixed"), Run(["true"]), Output("o")])
	sandboxed = match ConfigToModel.convert(settings.append(built)) {
		Ok(model) => Project.validate(model).is_err()
		Err(why) => why.contains("b cannot use environment mixed: FetchLocked")
	}
	match ConfigToModel.convert(settings) {
		Ok(model) => {
			both = Request.Run("both", [])
			planned_with = |lock| Std.plan_nix(model, both, { ..context, lock })
			entered = match planned_with(pinned).map_ok(|p| p.steps) {
				Ok([.., ExpectPrograms(check), Realise(realise), Run(task)]) =>
					check.programs == ["git"]
						and realise.bin == bin
						and realise.programs.map(|p| (p.name, p.sha256))
							== [("tool", sha256)]
						and task.argv.take_last(entering.len()) == entering
				_ => Bool.False
			}
			not_downloads = "environment mixed has tools that are not downloads: "
			entered
				and failed(planned_with(nix_lock)) == "missing_direct_lock"
				and DirectBackend.fit(model, both)
					== Err("${not_downloads}default#hello")
				and sandboxed
		}
		Err(_) => Bool.False
	}
}

# direct runs a workflow of tasks, which Nix leaves to it, refuses one with a
# build, and update with a name only for a FetchLocked file, which Nix leaves
# to it too.
expect {
	settings = [
		Name("direct"),
		Systems(["x86_64-linux"]),
		FetchLocked(
			"tool",
			[
				{
					system: "x86_64-linux",
					url: "https://example.com/t",
					mirrors: [],
					program: File,
				},
			],
		),
		Environment("dev", [Tools(["tool#tool"])]),
		Task("t", [Use("dev"), Run(["tool"])]),
		Environment("make", [Tools(["gnumake"])]),
		Build("app", [Use("make"), Run(["true"]), Output("out")]),
		Workflow("tasks", [RunTask("t", [])]),
		Workflow("all", [RunTask("t", []), BuildArtifact("app")]),
	]
	fits = |command, backend, args|
		match ConfigToModel.convert(settings) {
			Ok(model) =>
				Std.implementations(model)
					.find_first(|i| i.command == command and i.backend == On(backend))
					.map_ok(|i| (i.fit)(args).is_ok())
					?? Bool.False
			Err(_) => Bool.False
		}
	inputs = |name| [{ name: "inputs", value: Many([name]) }]
	fits("workflow", "direct", [{ name: "workflow", value: Present("tasks") }])
		and !fits("workflow", "nix", [{ name: "workflow", value: Present("tasks") }])
		and !fits("workflow", "direct", [{ name: "workflow", value: Present("all") }])
		and fits("update", "direct", inputs("tool"))
		and !fits("update", "nix", inputs("tool"))
}

# A Default build is what `kai build` builds without a name, and its help says
# so; without one the name is required. Only one build may be Default.
expect {
	defaults = |settings|
		ConfigToModel.convert(settings).map_ok(
			|model|
				Std.commands(model).keep_if(|c| c.name == "build").join_map(
					|build|
						build.args.join_map(
							|arg|
								match arg {
									Name(n) => [(n.default, n.help)]
									_ => []
								},
						),
				),
		)
	default = Build("main", [Use("dev"), Default, Run(["make"]), Output("out")])
	defaults(planning.append(default))
		== Ok([(Default("main"), "The build to run (default: main).")])
		and defaults(planning) == Ok([(Required, "The build to run.")])
		and defaults(
			planning
				.append(default)
				.append(Build("other", [Use("dev"), Default, Run(["make"]), Output("o")])),
		)
			== Err("several builds are Default: main, other")
}

# A system only direct serves needs every environment to be downloads there,
# and Nix's flake leaves it out.
expect {
	both = Systems(["x86_64-linux", "x86_64-windows"])
	linux_hello = OnSystems(["x86_64-linux"], [Tools(["hello"])])
	nix_only = Environment("dev", [Tools(["hello"])])
	mixed = [Name("mixed"), both, Environment("dev", [linux_hello])]
	refused = "x86_64-windows has no Nix or Guix: environment dev has tools "
		.concat("that are not downloads: default#hello")
	update = |model|
		Std.implementations(model)
			.keep_if(|i| i.command == "update" and i.backend == On("nix"))
			.map(|i| (i.plan)(context).is_ok())
	match Std.checked_model(mixed) {
		Ok(model) =>
			Std.on_nix(model).systems == ["x86_64-linux"]
				and update(model) == [Bool.True]
				and Std.checked_model([both, Name("bad"), nix_only]) == Err(refused)
		Err(_) => Bool.False
	}
}
