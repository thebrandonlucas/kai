# std's settings are today's Kaifile settings. std declares kai's standard
# commands (shell, run, build, workflow, update, ir), the nix and guix
# backends, and implementations planning from the settings' Kaifile IR.
import pf.Backend
import pf.Command
import Config
import pf.Implementation
import pf.Kaifile
import pf.Layout
import Lower
import pf.Plan
import pf.Plugin
import ir.Ir
import ir.Project
import ir.Request
import ir.LockFile
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
		match Lower.lower(settings) {
			Ok(ir) =>
				Plugin.new({
					name: "std",
					version: "",
					describe: ir.to_str(),
					commands: Std.commands(ir),
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
					implementations: Std.implementations(ir),
				})
			Err(problem) => Plugin.invalid("std", [problem])
		}

	commands : Ir -> List(Command)
	commands = |ir| {
		choice = |value, summary| { value, summary, details: [] }
		command = |name, page, args, lock|
			Command.{ name, summary: page.description, help: page, args, lock }
		[
			command(
				"shell",
				Pages.shell,
				[
					Name({
						name: "name",
						help: "The shell to enter (default: default).",
						choices: ir.shells.map(
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
						choices: ir.tasks.map(
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
						choices: ir.builds.map(
							|b| choice(b.name, "Output ${b.output} [${b.environment}]"),
						),
						default: Required,
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
						choices: ir.workflows.map(
							|w| choice(w.name, Str.join_with(w.steps.map(Std.step_text), ", ")),
						),
						default: Required,
					}),
				],
				ReadsLock,
			),
			command("update", Pages.update, [], OwnsLock),
			command("ir", Pages.ir, [], ReadsLock),
		]
	}

	step_text : Ir.WorkflowStep -> Str
	step_text = |step|
		match step {
			RunTask(task, _) => "run ${task}"
			BuildArtifact(build) => "build ${build}"
			RunWorkflow(name) => "workflow ${name}"
		}

	## The IR request a command's parsed arguments name.
	request : Str, Command.Args -> Try(Request, Str)
	request = |command, args|
		match command {
			"shell" => {
				command_words = Command.trailing(args, "command")
				Ok(Request.Shell(Command.name(args, "name"), command_words))
			}
			"run" =>
				Ok(Request.Run(Command.name(args, "task"), Command.trailing(args, "args")))
			"build" => Ok(Request.Build(Command.name(args, "name")))
			"workflow" => Ok(Request.Workflow(Command.name(args, "name")))
			_ => Err("std has no ${command} request")
		}

	implementations : Ir -> List(Implementation)
	implementations = |ir| {
		atomic = ["shell", "run", "build", "workflow"]
		nix = atomic.map(
			|command|
				Implementation.{
					command,
					backend: On("nix"),
					fit: |args| Std.fit_nix(ir, Std.request(command, args)?),
					plan: |ctx| Std.plan_nix(ir, Std.request(command, ctx.args)?, ctx),
				},
		)
		guix = atomic.map(
			|command|
				Implementation.{
					command,
					backend: On("guix"),
					fit: |args| GuixBackend.fit(ir, Std.request(command, args)?),
					plan: |ctx| {
						wanted = Std.request(command, ctx.args)?
						locked = Std.guix_pins(ctx)?
						GuixBackend.request_steps(ir, wanted, ctx.layout, locked)
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
					fit: |_| Std.lockable(ir),
					plan: |ctx| Std.update_nix(ir, ctx),
				},
				Implementation.{
					command: "update",
					backend: On("guix"),
					fit: |_| Std.guix_lockable(ir),
					plan: |ctx| Std.update_guix(ctx),
				},
				Implementation.{
					command: "ir",
					backend: Independent,
					fit: |_| Ok({}),
					plan: |_| {
						text = Str.drop_suffix(ir.to_str(), "\n")
						Ok(Plan.{ steps: [Print(text)], next: Done })
					},
				},
			])
	}

	## Whether Nix can serve the requested closure; unrelated shells, tasks
	## and builds never matter. Nix planning checks builds itself.
	fit_nix : Ir, Request -> Try({}, Str)
	fit_nix = |ir, wanted| {
		environment = match wanted {
			Request.Shell(name, _) =>
				ir.shells.find_first(|s| s.name == name)
					.map_ok(|s| s.environment)
					.map_err(|_| "unknown shell: ${name}")?
			Request.Run(name, _) =>
				ir.tasks.find_first(|t| t.name == name)
					.map_ok(|t| t.environment)
					.map_err(|_| "unknown task: ${name}")?
			_ => return Ok({})
		}
		Project.check_environment(ir, Nix, environment)
	}

	## Nix plans read the lock authority; its absence is a planning failure.
	plan_nix : Ir, Request, Implementation.Context -> Try(Plan, Str)
	plan_nix = |ir, wanted, ctx| {
		layout = Std.nix_layout(ctx.layout)
		path = ctx.layout.lock_path
		unreadable = |why|
			"cannot read the lock file ${path}: ${why}; run `kai update`"
		rendering = |message| "cannot generate the Nix files: ${message}"
		target = ctx.host.system
		NixBackend.preflight(ir, wanted, target, layout).map_err(rendering)?
		text = match ctx.lock {
			Present(contents) => contents
			Absent => return Err("no lock file at ${path}; run `kai update`")
		}
		locks = Locks.decode(text).map_err(unreadable)?
		NixBackend.plan(ir, wanted, target, layout, locks).map_err(rendering)
	}

	Run : { environment : Str, argv : List(Str), what : Str }

	## Plan `argv` inside std environment `environment` from the locked Nix
	## inputs, as a task would run: how a plugin runs a tool the project
	## declares. `what` names the step in progress and errors.
	run_in : List(Config.Setting), Implementation.Context, Run -> Try(Plan, Str)
	run_in = |settings, ctx, { environment, argv, what }| {
		ir = Lower.lower(settings)?
		task = "_kai_plugin_run"
		with_task = Ir.{
			format: ir.format,
			name: ir.name,
			requires_: ir.requires_,
			systems: ir.systems,
			sources: ir.sources,
			inputs: ir.inputs,
			environments: ir.environments,
			shells: ir.shells,
			tasks: ir.tasks.append({ name: task, environment, run: argv }),
			build_sources: ir.build_sources,
			builds: ir.builds,
			workflows: ir.workflows,
			extensions: ir.extensions,
			raw: ir.raw,
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

	## The Guix channel pins in the lock, or why they are missing or stale.
	guix_pins : Implementation.Context -> Try(List(GuixBackend.Pin), Str)
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
		GuixBackend.pinned([GuixBackend.default_channel], section)
	}

	## Guix has something to lock when any environment can run on it.
	guix_lockable : Ir -> Try({}, Str)
	guix_lockable = |ir| {
		guix = |e| Project.check_environment(ir, Guix, e.name).is_ok()
		if ir.environments.any(guix) {
			Ok({})
		} else {
			Err("no environment can run on Guix")
		}
	}

	## Phase 0 resolves the channels with the installed `guix repl` and asks
	## kai for the result; phase 1 validates it and publishes the lock's guix
	## section, keeping the others.
	update_guix : Implementation.Context -> Try(Plan, Str)
	update_guix = |ctx| {
		dir = "${ctx.layout.generated_root}/guix"
		result = "${dir}/lock-result.json"
		channels = [GuixBackend.default_channel]
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
				argv = ["guix", "repl", "-q", "--", script, result, unpinned]
				Ok(
					Plan.{
						steps: [Write(files), Run({ what: "guix lock", argv, output: Inherit })],
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
				contents = LockFile.splice(ctx.lock, "guix", GuixBackend.section(pinned))?
				publish = PublishLock({ previous: ctx.lock, contents })
				Ok(Plan.{ steps: [publish], next: Done })
			}
		}
	}

	## Nix has nothing to lock in a project using only Guix sources.
	lockable : Ir -> Try({}, Str)
	lockable = |ir| {
		used = ir.environments.join_map(|e| e.tools.map(|t| t.source))
		guix = |name|
			ir.sources.any(
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
	update_nix : Ir, Implementation.Context -> Try(Plan, Str)
	update_nix = |ir, ctx| {
		layout = Std.nix_layout(ctx.layout)
		target = ctx.host.system
		backend_lock = "${layout.generated_root}/flake.lock"
		match ctx.phase {
			0 => {
				files = NixBackend.update_files(ir, target, layout)?
				locals = NixBackend.local_checks(ir, target, layout)?
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
				locks = Locks.from_nix(ir, layout, resolved)
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
	valid.map_ok(|ir| ir.contains("(name \"x\")")) == Ok(Bool.True)
		and Kaifile.validate(Std.kaifile([]))
			== Err("std: MissingName: declare Name once")
}
