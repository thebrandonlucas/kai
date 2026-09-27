# What a Kaifile.roc provides: its plugins, checked while it compiles, and
# the candidate plans for one parsed command.
import Backend
import Command
import Layout
import Plan
import Implementation
import Plugin
import Protocol

Kaifile := { plugins : List(Plugin) }.{
	Choice : [Auto, Only(Str)]

	Contexts : Str -> Implementation.Context

	new : List(Plugin) -> Kaifile
	new = |plugins| Kaifile.{ plugins }

	## Every backend, in declaration order across plugins: Auto's preference.
	backends : Kaifile -> List(Backend)
	backends = |kaifile| kaifile.plugins.join_map(|p| p.backends)

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
		owner = kaifile.plugins.find_first(
			|p| p.commands.any(|c| c.name == command),
		).map_ok(|p| p.name) ?? ""
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
		Candidates({ command, plugin: owner, choice, options })
	}

	## The project description kai reads, or why the plugins are invalid:
	## a plugin's problems, a plugin named twice, or not exactly one plugin
	## describing the project.
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
		match kaifile.plugins.keep_if(|p| !p.describe.is_empty()) {
			[one] => Ok(one.describe)
			[] => Err("no plugin describes the project")
			_ => Err("more than one plugin describes the project")
		}
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

# One describing plugin is the description; problems, repeated names and
# zero or several descriptions are refused.
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
	([described("x", "")], Err("no plugin describes the project")),
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
