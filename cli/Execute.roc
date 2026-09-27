# Execute a command the Kaifile answered with candidate plans: probe their
# backends lazily, choose one, check its whole plan and run the steps in
# order, then continue a plan that asks to observe files. Only a command
# that owns the lock may publish it.
import pf.Cmd
import pf.Path
import pf.Stderr
import pf.Stdin
import pf.Stdout

import api.Layout
import api.Plan
import api.Protocol
import api.Sexpr

import Output
import Selection
import Snapshot
import Update
import Workspace

Execute := [].{
	# --yes, --dry-run, and whether a person can answer a confirmation.
	Options : { yes : Bool, dry_run : Bool, interactive : Bool }

	Lock : [ReadsLock, OwnsLock]

	Observed : List({ path : Str, contents : [Missing, Text(Str)] })

	Answer : {
		choice : Selection.Choice,
		lock : Lock,
		options : List(Selection.Candidate),
	}

	# Ask the Kaifile to continue the chosen backend's plan.
	Resume(err) : Str, U64, Observed => Try(Protocol.Body, err)

	# Probe fitting candidates in order, each program once, until one is
	# usable; run the chosen plan and any continuation it asks for. A chosen
	# plan that failed is reported, never replaced by another backend's.
	command! : Answer, Resume(_), Layout, Output.Mode, Options, Str => Try({}, _)
	command! = |answer, resume!, layout, mode, options, workflow| {
		# A lock owner run without --backend refreshes every installed backend
		# that fits, in preference order; every other command runs one.
		every = answer.lock == OwnsLock and answer.choice == Auto
		var $observed = []
		var $found = Bool.False
		for candidate in answer.options.keep_if(Selection.fits) {
			if every or !$found {
				for check in candidate.probes {
					if !$observed.any(|(program, _)| program == check.program) {
						$observed = $observed.append(
							(check.program, Execute.probe!(check.program, check.flag)),
						)
					}
				}
				seen = $observed
				$found = Selection.status(candidate, Execute.lookup(seen)) == Usable
			}
		}
		probe = Execute.lookup($observed)
		chosen = Selection.choose(answer.choice, answer.options, probe)?
		usable = |c| Selection.fits(c) and Selection.status(c, probe) == Usable
		ran = if every answer.options.keep_if(usable) else [chosen]
		for candidate in ran {
			if candidate.backend != "" {
				why = if ran.len() > 1 {
					"using ${candidate.backend} (updating every installed backend that fits)"
				} else {
					Selection.explain(answer.choice, answer.options, probe, candidate)
				}
				backend = [("backend", Output.text(candidate.backend))]
				Output.note!(mode, "kai: ${why}", Output.event("backend", why, backend))?
			}
			plan = Execute.planned(candidate.outcome)?
			Execute.follow!(
				{ backend: candidate.backend, lock: answer.lock, workflow },
				plan,
				0,
				resume!,
				layout,
				mode,
				options,
			)?
		}
		Ok({})
	}

	# Run a plan and every continuation it asks for, on one backend.
	follow! = |which, current, phase, resume!, layout, mode, options| {
		{ backend, lock, workflow } = which
		Execute.run!(current, lock, layout, mode, options, workflow)?
		match current.next {
			Done => Ok({})
			Observe(_) if options.dry_run => Ok({})
			Observe(_) if phase >= 3 =>
				Err(UnsafePlan("a plan may continue at most 3 times"))
			Observe(paths) => {
				body = resume!(backend, phase + 1, Execute.observe!(paths)?)?
				next = match body {
					Candidates({ options: [only], .. }) => Execute.planned(only.outcome)?
					Refused(why) => return Err(Refused(why))
					_ => return Err(PlanFailed("the Kaifile did not continue the plan"))
				}
				Execute.follow!(
					{ backend, lock, workflow },
					next,
					phase + 1,
					resume!,
					layout,
					mode,
					options,
				)
			}
		}
	}

	Outcome : [Unfit(Str), Planned(Plan), Failed(Str)]

	planned : Outcome -> Try(Plan, [PlanFailed(Str)])
	planned = |outcome|
		match outcome {
			Planned(plan) => Ok(plan)
			Failed(message) | Unfit(message) => Err(PlanFailed(message))
		}

	lookup : List((Str, Selection.Probe)) -> (Str -> Selection.Probe)
	lookup = |observed| |program|
		observed.find_first(|(name, _)| name == program).map_ok(|(_, p)| p)
			?? Unchecked

	# A continuation's files, each at most 1 MiB; validation keeps them in
	# the generated root.
	observe! : List(Str) => Try(Observed, _)
	observe! = |paths| {
		var $observed = []
		for path in paths {
			Workspace.safe_path!(path)?
			contents = match Workspace.path(path).type!() {
				Ok(IsFile) => {
					if Workspace.path(path).size_in_bytes!()? > 1_048_576 {
						return Err(UnsafePlan("observed file over 1 MiB: ${path}"))
					}
					Text(Workspace.path(path).read_utf8!()?)
				}
				Err(PathErr(NotFound, _)) => Missing
				_ => return Err(UnsafePath(path))
			}
			$observed = $observed.append({ path, contents })
		}
		Ok($observed)
	}

	# A bounded, side-effect-free check that an executable runs at all.
	probe! : Str, [DoubleDashVersion, DashV, VersionWord] => Selection.Probe
	probe! = |program, flag| {
		arg = match flag {
			DoubleDashVersion => "--version"
			DashV => "-v"
			VersionWord => "version"
		}
		version = Cmd.new_str(program).args_str([arg]).timeout_ms(10000)
		match version.run!() {
			Ok({ status: Exited(0), .. }) => Usable
			Ok({ status: Exited(code), .. }) =>
				Unusable("`${program} ${arg}` exited with code ${code.to_str()}")
			Ok({ status: Signaled(signal), .. }) =>
				Unusable("`${program} ${arg}` got signal ${signal.to_str()}")
			Err(IO(NotFound)) => Missing
			Err(Timeout(_)) => Unusable("`${program} ${arg}` timed out")
			Err(err) => Unusable(Str.inspect(err))
		}
	}

	# Check the whole plan, then run its steps in order; the first failure
	# stops the plan. Each Stage opens a numbered workflow step that the next
	# Stage or the end closes.
	run! : Plan, Lock, Layout, Output.Mode, Options, Str => Try({}, _)
	run! = |plan, lock, layout, mode, options, workflow| {
		Execute.validate(plan, layout, lock)?
		if options.dry_run {
			text = Sexpr.to_str(plan)
			fields = [("plan", Output.text(text))]
			return Output.result!(mode, text, Output.event("plan", "dry run", fields))
		}
		Execute.confirmable(plan, options)?
		if plan.steps.any(Execute.uses_workspace) {
			Workspace.prepare!(layout)?
		}
		count = plan.steps.count_if(
			|step| match step {
				Stage(_) => Bool.True
				_ => Bool.False
			},
		)
		var $index = 0
		var $finished = ""
		for step in plan.steps {
			match step {
				Stage(label) => {
					Execute.finish!(mode, $finished)?
					$index = $index + 1
					progress = Output.step(workflow, $index, count, label)
					Output.note!(mode, progress.human, progress.started)?
					$finished = progress.finished
				}
				_ => Execute.step!(step, layout, mode, options)?
			}
		}
		Execute.finish!(mode, $finished)
	}

	# Close the open workflow step, if any.
	finish! : Output.Mode, Str => Try({}, _)
	finish! = |mode, finished|
		if finished.is_empty() Ok({}) else Output.json!(mode, finished)

	# Every step is checked before the first runs: files only beneath the
	# generated root, the snapshot and runner only in the workspace, verified
	# paths only in the project, and every command exact argv naming a
	# program. Steps this kai cannot run yet are refused up front.
	validate : Plan, Layout, Lock -> Try({}, [UnsafePlan(Str)])
	validate = |plan, layout, lock| {
		for step in plan.steps {
			Execute.check(step, layout, lock).map_err(|why| UnsafePlan(why))?
		}
		match plan.next {
			Done => Ok({})
			Observe(paths) =>
				match paths.find_first(|p| !Execute.under(p, layout.generated_root)) {
					Ok(path) =>
						Err(UnsafePlan("observes a file outside the generated files: ${path}"))
					Err(_) => Ok({})
				}
			}
	}

	under : Str, Str -> Bool
	under = |path, root|
		Workspace.normalize(path) == path and path.starts_with("${root}/")

	check : Plan.Step, Layout, Lock -> Try({}, Str)
	check = |step, layout, lock| {
		command = |argv|
			match argv {
				[program, ..] =>
					if
						program.is_empty()
							or program.starts_with("-")
								or (program.contains("/") and !program.starts_with("/"))
							{
								Err("not a program name or absolute path: ${program}")
							} else {
								Ok({})
							}
				[] => Err("an empty command")
			}
		match step {
			Write(files) =>
				match files.find_first(
					|file|
						!Workspace.stageable(file, layout)
							or !under(file.path, layout.generated_root),
				) {
					Ok(file) => Err("writes outside the generated files: ${file.path}")
					Err(_) => Ok({})
				}
			VerifyPath({ path, argv, .. }) =>
				if under(path, layout.project_root) {
					command(argv)
				} else {
					Err("verifies a path outside the project: ${path}")
				}
			CheckSource(path) =>
				if under(path, layout.project_root) {
					Ok({})
				} else {
					Err("checks a source outside the project: ${path}")
				}
			Snapshot({ destination, .. }) | InstallRunner({ destination }) =>
				if under(destination, layout.workspace) {
					Ok({})
				} else {
					Err("writes outside the workspace: ${destination}")
				}
			Run({ argv, .. }) => command(argv)
			PublishLock(_) =>
				match lock {
					OwnsLock => Ok({})
					ReadsLock => Err("only a command that owns the lock publishes it")
				}
			Note(_) | Print(_) | Stage(_) | Confirm(_) => Ok({})
		}
	}

	# Without --yes, a plan that asks for confirmation needs a person at a
	# terminal; otherwise it fails before its first effect.
	confirmable : Plan, Options -> Try({}, [ConfirmationRequired(Str)])
	confirmable = |plan, options| {
		prompts = plan.steps.keep_oks(
			|step|
				match step {
					Confirm(prompt) => Ok(prompt)
					_ => Err({})
				},
		)
		match prompts.first() {
			Ok(prompt) if !options.yes and !options.interactive =>
				Err(ConfirmationRequired(prompt))
			_ => Ok({})
		}
	}

	uses_workspace : Plan.Step -> Bool
	uses_workspace = |step|
		match step {
			Write(_) | Snapshot(_) | InstallRunner(_) => Bool.True
			_ => Bool.False
		}

	# One step's effect. Children run from the project root; a failing child
	# stops the plan.
	step! : Plan.Step, Layout, Output.Mode, Options => Try({}, _)
	step! = |step, layout, mode, options| {
		root = layout.project_root
		match step {
			Note(message) =>
				Output.note!(mode, "kai: ${message}", Output.event("note", message, []))
			Print(text) =>
				Output.result!(mode, text, Output.event("result", text, []))
			Stage(_) => Ok({})
			Write(files) => Workspace.stage!(files, layout)
			VerifyPath({ path, argv, stdout }) => {
				Workspace.safe_source!(path)?
				(program, args) = match argv {
					[first, .. as rest] => (first, rest)
					[] => return Err(RenderFailed("the plan has an empty command"))
				}
				observed = Cmd.new_str(program)
					.args_str(args)
					.cwd(Workspace.path(root))
					.exec_output!()?
				Stderr.write!(observed.stderr_utf8_lossy)?
				if observed.stdout_utf8.trim() != stdout {
					return Err(LocalChanged(path))
				}
				Ok({})
			}
			CheckSource(path) => Workspace.safe_source!(path)
			Snapshot(snapshot) => Snapshot.snapshot!(snapshot)
			InstallRunner({ destination }) => Workspace.install_runner!(destination)
			Run({ what, argv, output: Inherit }) => Execute.child!(argv, what, root)
			Run({ what, argv, output: Artifact(artifact) }) =>
				Execute.build!(argv, what, artifact, root, mode)
			Confirm(prompt) =>
				if options.yes {
					Ok({})
				} else {
					Stderr.write!("kai: ${prompt} [y/N] ")?
					answer = Stdin.line!() ?? ""
					if ["y", "yes"].contains(answer.trim()) {
						Ok({})
					} else {
						Err(Declined(prompt))
					}
				}
			PublishLock({ previous, contents }) => {
				prior = match previous {
					Present(text) => Present(text.to_utf8())
					Absent => Absent
				}
				Update.publish!(layout.lock_path, prior, contents)?
				updated = "updated ${layout.lock_path}"
				fields = [("lock", Output.text(layout.lock_path))]
				Output.result!(mode, updated, Output.event("update", updated, fields))
			}
		}
	}

	# Resolve the requested artifact with the planned command: its store path
	# on stdout, only after success.
	build! : List(Str), Str, Plan.Artifact, Str, Output.Mode => Try({}, _)
	build! = |argv, what, artifact, root, mode| {
		{ name, label, output: declared } = artifact
		Stderr.line!("building ${name}: ${label} (output ${declared})")?
		(program, args) = match argv {
			[first, .. as rest] => (first, rest)
			[] => return Err(RenderFailed("the plan has no build command"))
		}
		output = Cmd.new_str(program)
			.args_str(args)
			.cwd(Workspace.path(root))
			.stderr(Inherit)
			.run!()?
		match output.status {
			Exited(0) => {
				path = Str.from_utf8_lossy(output.stdout_bytes).trim()
				built = "built ${name}: ${label} -> ${path}"
				fields = [
					("name", Output.text(name)),
					("installable", Output.text(label)),
					("output", Output.text(declared)),
					("path", Output.text(path)),
				]
				match mode {
					Human => {
						Stdout.write_bytes!(output.stdout_bytes)?
						Stderr.line!(built)
					}
					Json => Stdout.line!(Output.event("artifact", built, fields))
				}
			}
			Exited(code) => Err(ChildExited(what, code))
			Signaled(signal) => Err(ChildExited(what, 128 + signal))
		}
	}

	# Run argv from the project root with inherited stdio.
	child! = |argv, what, root|
		match argv {
			[program, .. as args] => {
				code = Cmd.new_str(program)
					.args_str(args)
					.cwd(Workspace.path(root))
					.exec_exit_code!()?
				if code == 0 Ok({}) else Err(ChildExited(what, code))
			}
			[] => Err(RenderFailed("the plan has an empty command"))
		}

	# A child's status becomes kai's own; statuses a process cannot exit with,
	# such as a signal report, become a generic failure.
	exit_code : I32 -> I32
	exit_code = |code| if code > 0 and code < 256 code else 1
}

# A failing child's status is kept rather than collapsed to 1.
expect [(7, 7), (1, 1), (255, 255), (256, 1), (-1, 1), (0, 1)]
	.all(|(code, exit)| Execute.exit_code(code) == exit)

layout : Layout
layout = Layout.{
	project_root: "/p",
	workspace: "/p/.kai",
	generated_root: "/p/.kai/generated",
	lock_path: "/p/.kai/lock.json",
}

validated : List(Plan.Step) -> Try({}, [UnsafePlan(Str)])
validated = |steps|
	Execute.validate(Plan.{ steps, next: Done }, layout, ReadsLock)

# A build's steps pass: files beneath the generated root, verified project
# sources, the snapshot and runner in the workspace, exact argv.
expect
	validated([
		Stage("build app"),
		VerifyPath({ path: "/p/vendor", argv: ["nix", "hash"], stdout: "x" }),
		Snapshot({ root: "/p", destination: "/p/.kai/snapshot", exclude: [] }),
		InstallRunner({ destination: "/p/.kai/build-runner" }),
		Write([{ path: "/p/.kai/generated/flake.nix", contents: "" }]),
		Run({ what: "build app", argv: ["/bin/nix", "build"], output: Inherit }),
		Note("n"),
	])
		== Ok({})

# Each unsafe or unsupported step refuses the whole plan.
expect [
	Write([{ path: "/p/.kai/lock.json", contents: "" }]),
	Write([{ path: "/p/.kai/generated/../lock.json", contents: "" }]),
	Write([{ path: "/p/flake.nix", contents: "" }]),
	VerifyPath({ path: "/etc", argv: ["nix"], stdout: "" }),
	VerifyPath({ path: "/p/../etc", argv: ["nix"], stdout: "" }),
	VerifyPath({ path: "/p/src", argv: [], stdout: "" }),
	Snapshot({ root: "/p", destination: "/p/src", exclude: [] }),
	InstallRunner({ destination: "/tmp/runner" }),
	Run({ what: "t", argv: [], output: Inherit }),
	Run({ what: "t", argv: [""], output: Inherit }),
	Run({ what: "t", argv: ["-c"], output: Inherit }),
	Run({ what: "t", argv: ["bin/sh"], output: Inherit }),
	PublishLock({ previous: Absent, contents: "{}" }),
]
	.all(
		|bad|
			match validated([Note("before"), bad]) {
				Err(UnsafePlan(_)) => Bool.True
				Ok(_) => Bool.False
			},
	)

# A continuation observes only generated files, and only a command that
# owns the lock may publish it.
expect {
	observing = |path| Plan.{ steps: [], next: Observe([path]) }
	publish = Plan.{
		steps: [PublishLock({ previous: Absent, contents: "{}" })],
		next: Done,
	}
	checked = |plan, lock| Execute.validate(plan, layout, lock)
	checked(observing("/p/.kai/generated/flake.lock"), ReadsLock) == Ok({})
		and checked(observing("/p/.kai/lock.json"), ReadsLock) != Ok({})
			and Execute.validate(publish, layout, OwnsLock) == Ok({})
				and Execute.validate(publish, layout, ReadsLock) != Ok({})
}

# A confirmation needs --yes or a person at a terminal; otherwise the plan
# is refused before its first effect.
expect {
	asks = Plan.{ steps: [Note("n"), Confirm("delete?")], next: Done }
	quiet = Plan.{ steps: [Note("n")], next: Done }
	[
		(asks, Bool.False, Bool.False, Err(ConfirmationRequired("delete?"))),
		(asks, Bool.True, Bool.False, Ok({})),
		(asks, Bool.False, Bool.True, Ok({})),
		(quiet, Bool.False, Bool.False, Ok({})),
	].all(
		|(plan, yes, interactive, expected)|
			Execute.confirmable(plan, { yes, dry_run: Bool.False, interactive })
				== expected,
	)
}
