# The guix plugin: the guix backend, and std's shell, run, build, workflow
# and update on it, planned from std's settings through std.StdModel. The
# lock's guix section holds the channel commits and source hashes.
import pf.Backend
import pf.Command
import pf.Implementation
import pf.LockFile
import pf.Plan
import pf.Plugin
import std.Config
import std.InputName
import std.StdModel exposing [Model]
import GuixBackend

Guix := [].{

	Channel : GuixBackend.Channel

	## Channel adds a channel beside Guix's own: its name, git URL, branch
	## and introduction (first signed commit, signer's OpenPGP fingerprint).
	## Every Guix source then offers its packages; `kai update` locks its
	## commit.
	Setting : [Channel(InputName, Str, Str, [Introduction(Str, Str)])]

	## `project` is std's settings, whose environments Guix enters.
	plugin : List(Config.Setting), List(Setting) -> Plugin
	plugin = |project, settings| {
		channels = settings.map(
			|setting|
				match setting {
					Channel(name, url, branch, Introduction(commit, signer)) =>
						{ name: name.to_str(), url, branch, introduction: { commit, signer } }
				},
		)
		match Guix.checked(project, channels) {
			Ok(model) =>
				Plugin.new({
					name: "guix",
					version: "",
					describe: "",
					commands: [],
					backends: [
						Backend.{
							id: "guix",
							summary: "Guix shells",
							program: "guix",
							flag: DoubleDashVersion,
						},
					],
					implementations: Guix.implementations(model, channels),
				})
			Err(problem) => Plugin.invalid("guix", [problem])
		}
	}

	## std's model of `project`, once Guix accepts it and the channels.
	checked : List(Config.Setting), List(Channel) -> Try(Model, Str)
	checked = |project, channels| {
		model = StdModel.from_settings(project)?
		GuixBackend.check_settings(model, channels)?
		Ok(model)
	}

	implementations : Model, List(Channel) -> List(Implementation)
	implementations = |model, channels|
		["shell", "run", "build", "workflow"]
			.map(
				|command|
					Implementation.{
						command,
						backend: On("guix"),
						fit: |args| GuixBackend.fit(model, StdModel.request(command, args)?),
						plan: |ctx| {
							GuixBackend.check_system(ctx.host.system).map_err(Plan.fail)?
							wanted = StdModel.request(command, ctx.args).map_err(Plan.fail)?
							StdModel.known(model, wanted)?
							locked = Guix.pins(channels, ctx)?
							# Guix plans for the host, so it takes the host's OnSystems.
							host = StdModel.for_system(model, ctx.host.system)
							revised = StdModel.revised(host, ctx)
							GuixBackend.request_steps(revised, wanted, ctx.layout, locked)
								.map_err(|why| Guix.failure(command, why))
						},
					},
			)
			.append(
				Implementation.{
					command: "update",
					backend: On("guix"),
					fit: |args|
						if Command.trailing(args, "inputs").is_empty() {
							Guix.lockable(model)
						} else {
							Err("Guix updates all its pins together; name no inputs")
						},
					plan: |ctx| Guix.update(model, channels, ctx).map_err(Plan.fail),
				},
			)

	## The Guix pins in the lock, or why they are missing or stale.
	pins :
		List(Channel), Implementation.Context -> Try(GuixBackend.Locked, Plan.Failure)
	pins = |channels, ctx| {
		absent = "the lock has no Guix pins"
		missing = Guix.lock_failure("missing_guix_lock", absent)
		stale = "the Guix pins in the lock do not match the project's channels"
		section = match ctx.lock {
			Present(text) =>
				match LockFile.section(text, "guix").map_err(Plan.fail)? {
					Present(found) => found
					Absent => return Err(missing)
				}
			Absent => return Err(missing)
		}
		GuixBackend.read_lock(GuixBackend.project_channels(channels), section)
			.map_err(|_| Guix.lock_failure("stale_lock", stale))
	}

	## A lock problem that updating the Guix pins fixes.
	lock_failure : Str, Str -> Plan.Failure
	lock_failure = |code, message|
		{ code, message, hint: "kai --backend guix update", suggestions: [] }

	## Why a Guix plan failed: a source the lock has no hash for, or `why`.
	failure : Str, Str -> Plan.Failure
	failure = |command, why|
		if why == GuixBackend.stale_lock {
			Guix.lock_failure("stale_lock", why)
		} else {
			Plan.fail("cannot plan the Guix ${command}: ${why}")
		}

	## Guix has something to lock when any environment can run on it.
	lockable : Model -> Try({}, Str)
	lockable = |model| {
		guix = |e| GuixBackend.check_environment(model, e.name).is_ok()
		if (model.environments.any(guix)) Ok({})
		else Err("no environment can run on Guix")
	}

	## Phase 0 resolves the channels and hashes the path: sources with the
	## installed `guix repl` and asks kai for the result; phase 1 validates it
	## and publishes the lock's guix section, keeping the others.
	update :
		Model, List(Channel), Implementation.Context -> Try(Plan, Str)
	update = |model, declared, ctx| {
		GuixBackend.check_system(ctx.host.system)?
		dir = "${ctx.layout.generated_root}/guix"
		result = "${dir}/lock-result.json"
		channels = GuixBackend.project_channels(declared)
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
				lock = Run({
					description: "guix lock",
					argv,
					output: Inherit,
					secrets: [],
					removed_environment_variables: [],
					kept_environment_variables: [],
				})
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
}

import pf.Layout

# A shell, task, build and workflow on one environment Guix serves, and a
# path: source the builds may read.
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
	backend: "guix",
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

# The plan of the plugin's implementation of `command`, once it fits.
planned : Plugin, Str, Implementation.Context -> Try(Plan, Plan.Failure)
planned = |plugin, command, ctx| {
	found = plugin.implementations
		.find_first(|i| i.command == command)
		.map_err(|_| Plan.fail("no ${command} on guix"))?
	(found.fit)(ctx.args).map_err(Plan.fail)?
	(found.plan)(ctx)
}

guix = Guix.plugin(planning, [])

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

failed : Try(Plan, Plan.Failure) -> Str
failed = |result|
	match result {
		Ok(_) => ""
		Err(failure) => failure.code
	}

named : Str, Str -> Command.Args
named = |argument, name| [{ name: argument, value: Present(name) }]

pin = "0123456789abcdef0123456789abcdef01234567"

assets_hash = "0123456789abcdfghijklmnpqrsvwxyz0123456789abcdfghijk"

# The lock a phase 1 update publishes from what phase 0 observed.
published : Implementation.Context, Str, Str -> [Absent, Present(Str)]
published = |ctx, path, text| {
	resumed = { ..ctx, phase: 1, observed: [{ path, contents: Text(text) }] }
	match planned(guix, "update", resumed).map_ok(|plan| plan.steps) {
		Ok([PublishLock({ contents, .. }), ..]) => Present(contents)
		_ => Absent
	}
}

guix_lock = published(
	context,
	"/generated/guix/lock-result.json",
	"{\"channels\":[{\"name\":\"guix\",\"commit\":\"${pin}\"}],"
		.concat("\"sources\":[{\"name\":\"assets\",\"hash\":\"${assets_hash}\"}]}"),
)

time_machine = ["guix", "time-machine", "-C", "/generated/guix/channels.scm"]

guix_shell = ["--", "shell", "-q", "--pure", "--preserve=^KAI_OPERATOR_SHELL$"]

# Update resolves the channels with guix repl, then publishes the observed
# pins as the lock's guix section.
expect {
	dir = "/generated/guix"
	script = ["${dir}/lock.scm", "${dir}/lock-result.json"]
	argv = ["guix", "repl", "-q", "--"]
		.concat(script)
		.append("${dir}/channels-unpinned.scm")
		.concat(["assets", "/project/assets"])
	runs(planned(guix, "update", context))
		== Ok([{ description: "guix lock", argv }])
		and Guix.pins([], { ..context, lock: guix_lock })
			== Ok({
				channels: [{ channel: GuixBackend.default_channel, commit: pin }],
				sources: [{ name: "assets", path: "assets", hash: assets_hash }],
			})
}

# A shell runs guix shell at the locked channels; without the guix section,
# or with pins for other channels, it is refused.
expect {
	shell = { ..context, args: named("shell", "default"), lock: guix_lock }
	argv = time_machine.concat(guix_shell).append("hello")
	url = "https://example.com/nonguix"
	nonguix = Channel("nonguix", url, "master", Introduction(pin, pin))
	sectionless = { ..shell, lock: Present("{\"version\":2}") }
	runs(planned(guix, "shell", shell))
		== Ok([{ description: "shell default", argv }])
		and failed(planned(guix, "shell", sectionless)) == "missing_guix_lock"
		and failed(planned(Guix.plugin(planning, [nonguix]), "shell", shell))
			== "stale_lock"
}

# A task runs its command and trailing arguments in guix shell.
expect {
	args = [
		{ name: "task", value: Present("greet") },
		{ name: "args", value: Many(["a b"]) },
	]
	argv = time_machine
		.concat(guix_shell)
		.append("hello")
		.concat(["--", "hello", "-g", "hi", "a b"])
	runs(planned(guix, "run", { ..context, args, lock: guix_lock }))
		== Ok([{ description: "task greet", argv }])
}

# A build builds its generated file at the locked channels.
expect {
	build = { ..context, args: named("build", "app"), lock: guix_lock }
	scm = "/generated/guix/build-app.scm"
	argv = time_machine.concat(["--", "build", "-f", scm])
	runs(planned(guix, "build", build)) == Ok([{ description: "build app", argv }])
}

# A workflow stages each step in order.
expect {
	ci = { ..context, args: named("workflow", "ci"), lock: guix_lock }
	stages(planned(guix, "workflow", ci)) == Ok(["run greet", "build app"])
}

# The plugin refuses invalid channels, Guix's own name among them, and tools
# of a Guix source that are no Guix specification.
expect {
	introduction = Introduction(pin, pin)
	problems = |plugin| plugin.problems
	guix_tool = |tool| [
		Name("x"),
		Packages("guix", From(GuixPackages("guix"))),
		Environment("dev", [Tools([tool])]),
	]
	valid = Guix.plugin(guix_tool("guix#hello@2.12:out"), [])
	own = Channel("guix", "https://example.com/guix", "master", introduction)
	url = "https://example.com/other"
	unsigned = Channel("other", url, "master", Introduction("", pin))
	problems(valid) == []
		and problems(Guix.plugin(planning, [own]))
			== ["DuplicateGuixChannel: guix"]
		and problems(Guix.plugin(planning, [unsigned]))
			== ["invalid Guix channel: other"]
		and problems(Guix.plugin(guix_tool("guix#git::out"), []))
			== ["invalid Guix tool: git::out"]
}
