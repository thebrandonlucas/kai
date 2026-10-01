# What a Kaifile.roc provides: its plugins, checked while it compiles, and
# the candidate plans for one parsed command.
import Backend
import Command
import Layout
import Plan
import Implementation
import Plugin
import Protocol

Kaifile := { plugins : List(Plugin), preference : List(Str) }.{
	Choice : [Auto, Only(Str)]

	Contexts : Str -> Implementation.Context

	new : List(Plugin) -> Kaifile
	new = |plugins| Kaifile.{ plugins, preference: [] }

	## Backend preference for Auto, before declaration order.
	prefer : Kaifile, List(Str) -> Kaifile
	prefer = |kaifile, preference| Kaifile.{ plugins: kaifile.plugins, preference }

	## Every backend in Auto's preference order: those named by `prefer`,
	## then declaration order across plugins.
	backends : Kaifile -> List(Backend)
	backends = |kaifile| {
		declared = kaifile.plugins.join_map(|p| p.backends)
		named = |id| declared.find_first(|b| b.id == id)
		preferred = kaifile.preference.keep_oks(named)
		preferred.concat(declared.keep_if(|b| !kaifile.preference.contains(b.id)))
	}

	## One option per implementation of `command` (section 6.1 of the plugins
	## plan): an unknown --backend is refused; an Independent implementation
	## ignores --backend; otherwise backends in preference order, or only the
	## chosen one. Only a fitting implementation is planned.
	## `context` gives each backend's plans what they may depend on.
	candidates : Kaifile, Str, Choice, Contexts -> Protocol.Body
	candidates = |kaifile, command, choice, context| {
		declared = Kaifile.backends(kaifile)
		ids = declared.map(|b| b.id)
		match choice {
			Only(id) if !ids.contains(id) =>
				return Refused("--backend must be one of ${Str.join_with(ids, ", ")}")
			_ => {}
		}
		owned = kaifile.plugins.join_map(
			|p| p.implementations.keep_if(|i| i.command == command).map(|i| (p.name, i)),
		)
		named = |c| c.name == command
		declaring = kaifile.plugins.find_first(|p| p.commands.any(named))
		owner = declaring.map_ok(|p| p.name) ?? ""
		lock = match declaring.map_ok(|p| p.commands.find_first(named)) {
			Ok(Ok(found)) => found.lock
			_ => ReadsLock
		}
		option = |(plugin, implementation), backend, probes| {
			ctx = context(backend)
			outcome = match (implementation.fit)(ctx.args) {
				Err(why) => Unfit(why)
				Ok({}) =>
					match (implementation.plan)(ctx) {
						Ok(plan) => Planned(plan)
						Err(message) => Failed(message)
					}
				}
			{ backend, plugin, probes, outcome }
		}
		independent = owned.keep_if(
			|(_, i)|
				match i.backend {
					Independent => Bool.True
					On(_) => Bool.False
				},
		)
		options = match independent {
			[one, ..] => [option(one, "", [])]
			[] =>
				declared
					.keep_if(
						|b|
							match choice {
								Auto => Bool.True
								Only(id) => b.id == id
							},
					)
					.join_map(
						|b|
							owned
								.keep_if(|(_, i)| i.backend == On(b.id))
								.map(
									|found|
										option(found, b.id, [{ program: b.program, flag: b.flag }]),
								),
					)
			}
		Candidates({ command, plugin: owner, choice, lock, options })
	}

	## The project description kai reads, or why the plugins are invalid:
	## a plugin's problems, a plugin named twice, a registry rule broken, or
	## more than one plugin describing the project.
	validate : Kaifile -> Try(Str, Str)
	validate = |kaifile| {
		var $names = []
		for plugin in kaifile.plugins {
			match plugin.problems {
				[] => {}
				problems => {
					reasons = Str.join_with(problems, "; ")
					return Err("${plugin.name}: ${reasons}")
				}
			}
			if $names.contains(plugin.name) {
				return Err("plugin ${plugin.name} is listed twice")
			}
			$names = $names.append(plugin.name)
		}
		Kaifile.registry(kaifile)?
		match kaifile.plugins.keep_if(|p| !p.describe.is_empty()) {
			[one] => Ok(one.describe)
			[] => Ok("")
			_ => Err("more than one plugin describes the project")
		}
	}

	## kai's own commands, which no plugin may declare.
	builtins = ["check", "help", "describe", "__build-runner"]

	## The commands, backends and implementations fit together.
	registry : Kaifile -> Try({}, Str)
	registry = |kaifile| {
		commands = kaifile.plugins.join_map(|p| p.commands.map(|c| (p.name, c)))
		declared = kaifile.plugins.join_map(|p| p.backends.map(|b| (p.name, b)))
		implementations = kaifile.plugins.join_map(
			|p| p.implementations.map(|i| (p.name, i)),
		)
		word = |b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9')
		lower = |text|
			!text.is_empty() and text.to_utf8().all(|b| word(b) or b == '-')
		var $seen = []
		for (plugin, command) in commands {
			if !lower(command.name) {
				return Err("${plugin}: invalid command name \"${command.name}\"")
			}
			if Kaifile.builtins.contains(command.name) {
				return Err("${plugin}: ${command.name} is a kai command")
			}
			if $seen.contains(command.name) {
				return Err(
					"command ${command.name} is declared twice; drop one with "
						.concat("Plugin.without_command"),
				)
			}
			$seen = $seen.append(command.name)
		}
		var $ids = []
		for (plugin, backend) in declared {
			if !lower(backend.id) or $ids.contains(backend.id) {
				id = backend.id
				return Err("${plugin}: backend ${id} is invalid or declared twice")
			}
			symbol = |b| ['.', '_', '+', '-'].contains(b)
			program = backend.program
			allowed = |b| word(b) or symbol(b)
			program_ok = !program.is_empty() and program.to_utf8().all(allowed)
			if !program_ok {
				id = backend.id
				return Err("${plugin}: backend ${id} probes an invalid program")
			}
			$ids = $ids.append(backend.id)
		}
		var $pairs = []
		for (plugin, implementation) in implementations {
			if !$seen.contains(implementation.command) {
				name = implementation.command
				return Err("${plugin}: implements unknown command ${name}")
			}
			backend = match implementation.backend {
				On(id) => id
				Independent => ""
			}
			if !backend.is_empty() and !$ids.contains(backend) {
				name = implementation.command
				return Err("${plugin}: ${name} uses unknown backend ${backend}")
			}
			if $pairs.contains((implementation.command, backend)) {
				target = if backend.is_empty() "no backend" else backend
				return Err(
					"${implementation.command} on ${target} "
						.concat("is implemented twice; drop one with Plugin.without"),
				)
			}
			$pairs = $pairs.append((implementation.command, backend))
		}
		for name in $seen {
			on = $pairs.keep_if(|(c, _)| c == name).map(|(_, b)| b)
			if on.is_empty() {
				return Err("command ${name} has no implementation")
			}
			if on.contains("") and on.len() > 1 {
				return Err("command ${name} mixes backend and backend-free plans")
			}
		}
		owners = commands.keep_if(|(_, c)| c.lock == OwnsLock)
		if owners.len() > 1 {
			return Err("only one command may own the lock")
		}
		Ok({})
	}
}

described = |name, text|
	Plugin.new({
		name,
		version: "1",
		describe: text,
		commands: [],
		backends: [],
		implementations: [],
	})

# One describing plugin is the description, none is an empty one; problems,
# repeated names and several descriptions are refused.
expect [
	([described("std", "(ir)")], Ok("(ir)")),
	([described("std", "(ir)"), described("x", "")], Ok("(ir)")),
	(
		[Plugin.invalid("std", ["no Name", "two Systems"])],
		Err("std: no Name; two Systems"),
	),
	(
		[described("std", "(ir)"), described("std", "")],
		Err("plugin std is listed twice"),
	),
	([described("x", "")], Ok("")),
	(
		[described("std", "(a)"), described("y", "(b)")],
		Err("more than one plugin describes the project"),
	),
].all(|(plugins, expected)| Kaifile.validate(Kaifile.new(plugins)) == expected)

planned = |text| Ok(Plan.{ steps: [Note(text)], next: Done })

toy : Kaifile
toy = {
	backend = |id|
		Backend.{ id, summary: id, program: id, flag: DoubleDashVersion }
	on = |command, id, fit, plan|
		Implementation.{ command, backend: On(id), fit: |_| fit, plan: |_| plan }
	shell = Command.{
		name: "shell",
		summary: "",
		help: { description: "", examples: [], config: [] },
		args: [],
		lock: ReadsLock,
	}
	Kaifile.new([
		Plugin.new({
			name: "std",
			version: "1",
			describe: "(ir)",
			commands: [shell],
			backends: [backend("nix"), backend("guix")],
			implementations: [
				on("shell", "nix", Ok({}), planned("nix shell")),
				on("shell", "guix", Err("uses overlays"), planned("unused")),
				on("build", "nix", Ok({}), Err("no lock")),
				Implementation.{
					command: "ir",
					backend: Independent,
					fit: |_| Ok({}),
					plan: |_| planned("ir"),
				},
			],
		}),
	])
}

context : Str -> Implementation.Context
context = |backend| {
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

outcomes = |command, choice|
	match Kaifile.candidates(toy, command, choice, context) {
		Candidates({ options, .. }) => Ok(options.map(|o| (o.backend, o.outcome)))
		Refused(why) => Err(why)
		_ => Err("other")
	}

# Candidates follow backend preference and --backend; an unknown backend is
# refused, an independent implementation ignores --backend, and a failed
# plan is kept for kai to report.
expect {
	note = |text| Planned(Plan.{ steps: [Note(text)], next: Done })
	overlays = Unfit("uses overlays")
	outcomes("shell", Auto) == Ok([("nix", note("nix shell")), ("guix", overlays)])
		and outcomes("shell", Only("guix")) == Ok([("guix", overlays)])
			and outcomes("shell", Only("apt"))
				== Err("--backend must be one of nix, guix")
				and outcomes("ir", Only("guix")) == Ok([("", note("ir"))])
					and outcomes("build", Auto) == Ok([("nix", Failed("no lock"))])
}

command = |name, lock|
	Command.{
		name,
		summary: "",
		help: { description: "", examples: [], config: [] },
		args: [],
		lock,
	}

implementing = |name, backend|
	Implementation.{
		command: name,
		backend,
		fit: |_| Ok({}),
		plan: |_| Err("unused"),
	}

plugin = |name, commands, backends, implementations|
	Plugin.new({
		name,
		version: "1",
		describe: "",
		commands,
		backends: backends.map(
			|id| Backend.{ id, summary: id, program: id, flag: DoubleDashVersion },
		),
		implementations,
	})

registered = |plugins| Kaifile.validate(Kaifile.new(plugins)).is_ok()

# Commands are unique and not kai's, implementations name declared commands
# and backends once, every command is implemented, one command owns the
# lock; without and without_command resolve the clashes.
expect {
	on = |name, id| implementing(name, On(id))
	free = |name| implementing(name, Independent)
	one = |name, commands, backends, impls|
		[plugin(name, commands, backends, impls)]
	reads = |name| command(name, ReadsLock)
	owns = |name| command(name, OwnsLock)
	deploy = plugin("deploy", [reads("deploy")], ["nix"], [on("deploy", "nix")])
	again = plugin("again", [reads("deploy")], [], [free("deploy")])
	y = plugin("y", [], [], [on("deploy", "nix")])
	unpaired = deploy.without({ command: "deploy", backend: "nix" })
	[
		registered([deploy]),
		!registered([deploy, again]),
		registered([deploy.without_command("deploy"), again]),
		!registered(one("x", [reads("check")], [], [free("check")])),
		!registered(one("x", [reads("up")], [], [on("up", "apt")])),
		!registered(one("x", [reads("up")], [], [])),
		!registered([deploy, y]),
		registered([unpaired, y]),
		!registered(one("x", [owns("a"), owns("b")], [], [free("a"), free("b")])),
	].all(|ok| ok)
}

# prefer puts named backends first; the rest keep declaration order.
expect
	Kaifile.new([plugin("std", [], ["nix", "guix"], [])])
		.prefer(["guix"])
		.backends()
		.map(|b| b.id)
		== ["guix", "nix"]
