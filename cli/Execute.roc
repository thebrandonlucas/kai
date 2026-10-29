# Execute a command the Kaifile answered with candidate plans: probe their
# backends lazily, choose one, check its whole plan and run the steps in
# order, then continue a plan that asks to observe files. Only a command
# that owns the lock may publish it.
import pf.Cmd
import pf.Duration
import pf.Env
import pf.OsStr
import pf.Path
import pf.Sleep
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
import Variables
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
		ran = if (every) answer.options.keep_if(usable) else [chosen]
		for candidate in ran {
			if candidate.backend != "" {
				why = if ran.len() > 1 {
					"using ${candidate.backend} (updating every installed backend that fits)"
				} else {
					Selection.explain(answer.choice, answer.options, probe, candidate)
				}
				backend = [("backend", Output.text(candidate.backend))]
				event = Output.event("backend", why, backend)
				# Only a fallback is worth a person's attention; machines get
				# every choice.
				fell_back = Selection.fell_back(answer.choice, answer.options, candidate)
				if ran.len() > 1 or fell_back {
					Output.note!(mode, "kai: ${why}", event)?
				} else {
					Output.json!(mode, event)?
				}
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
				observed = Execute.observe!(paths)?
				next_plan = Execute.continuation!(resume!, backend, phase + 1, observed)
				# When the Kaifile rejects the files it read back, such as a Nix
				# lock, none of them are left behind.
				if next_plan.is_err() {
					for path in paths {
						_ = Workspace.path(path).delete!()
					}
				}
				Execute.follow!(
					{ backend, lock, workflow },
					next_plan?,
					phase + 1,
					resume!,
					layout,
					mode,
					options,
				)
			}
		}
	}

	# The plan the Kaifile continues with once it has read the observed files.
	continuation! = |resume!, backend, phase, observed| {
		answer = resume!(backend, phase, observed)?
		match answer {
			Candidates({ options: [only], .. }) => Execute.planned(only.outcome)
			Refused(why) => Err(Refused(why))
			_ => Err(PlanFailed("the Kaifile did not continue the plan"))
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
		version = Cmd.new(OsStr.from_str(program))
			.arg(OsStr.from_str(arg))
			.timeout(Duration.seconds(10))
		match version.run!() {
			Ok(output) =>
				match output.status {
					Exited(0) => Usable
					Exited(code) =>
						Unusable("`${program} ${arg}` exited with code ${code.to_str()}")
					Signaled(signal) =>
						Unusable("`${program} ${arg}` got signal ${signal.to_str()}")
				}
			Err(CmdErr(StartFailed(NotFound, _))) => Missing
			Err(CmdErr(TimedOut(_))) => Unusable("`${program} ${arg}` timed out")
			Err(err) => Unusable(Str.inspect(err))
		}
	}

	# Check the whole plan, then run its steps in order; the first failure
	# stops the plan. Each Stage opens a numbered workflow step that the next
	# Stage or the end closes. A Run failing within a MayFail's Stages is
	# noted, and the plan continues after them.
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
		Execute.steps!(plan, layout, mode, workflow, options)
	}

	# A symbolic link in the workspace naming its holder's process ID is the
	# build lock, created atomically with its holder. Each build holds it from
	# its snapshot through its build command, so builds take turns while the
	# tasks around them, which may run kai build themselves, do not wait. A
	# lock whose holder is no longer running is taken over.
	hold! : Str, Output.Mode => Try({}, _)
	hold! = |guard, mode| {
		process = Execute.shell!("echo $PPID", [])?.stdout
		var $noted = ""
		var $held = Bool.False
		while !$held {
			match Path.symlink!(Workspace.path(process), Workspace.path(guard), File) {
				Ok({}) => {
					$held = Bool.True
				}
				Err(PathErr(AlreadyExists, _)) => {
					holder = match Workspace.path(guard).read_link!() {
						Ok(target) => target.to_str() ?? ""
						Err(PathErr(NotFound, _)) => "released"
						Err(_) => ""
					}
					numeric = holder.to_utf8().all(|byte| byte >= '0' and byte <= '9')
					message =
						if holder == "released" {
							""
						} else if holder.is_empty() or !numeric {
							"waiting for another kai build to release ${guard}; "
								.concat("if none is running, it is safe to remove it")
						} else if Execute.shell!("kill -0 \"$1\"", [holder])?.succeeded {
							"waiting for kai process ${holder} to release ${guard}"
						} else if Execute.take_over!(guard, holder)? {
							"took over a build lock left by a process that is no longer running"
						} else {
							""
						}
					if !message.is_empty() and message != $noted {
						Output.note!(mode, "kai: ${message}", Output.event("note", message, []))?
						$noted = message
					}
					Sleep.millis!(200)?
				}
				Err(err) => return Err(err)
			}
		}
		Ok({})
	}

	# Remove the lock a stopped process left, unless another kai took it over
	# first: the directory named after that process lets one kai do so.
	take_over! : Str, Str => Try(Bool, _)
	take_over! = |guard, holder| {
		marker = Workspace.path("${guard}.${holder}")
		match marker.create_dir!() {
			Ok({}) => {
				current = Workspace.path(guard).read_link!()
				stale = current.map_ok(|target| target.to_str() ?? "") == Ok(holder)
				if stale {
					_ = Workspace.path(guard).delete!()
				}
				_ = marker.delete_empty!()
				Ok(stale)
			}
			Err(PathErr(AlreadyExists, _)) => Ok(Bool.False)
			Err(err) => Err(err)
		}
	}

	# A shell script's trimmed stdout and whether it succeeded.
	shell! = |script, args| {
		ran = Cmd.new(OsStr.from_str("sh"))
			.args(["-c", script, "sh"].concat(args).map(OsStr.from_str))
			.run!()?
		stdout = Str.from_utf8_lossy(ran.stdout_bytes).trim()
		Ok({ stdout, succeeded: ran.status == Exited(0) })
	}

	steps! : Plan, Layout, Output.Mode, Str, Options => Try({}, _)
	steps! = |plan, layout, mode, workflow, options| {
		count = plan.steps.count_if(
			|step| match step {
				Stage(_) => Bool.True
				_ => Bool.False
			},
		)
		guard = "${layout.workspace}/build.lock"
		var $index = 0
		var $finished = ""
		var $holding = Bool.False
		# The last Stage of each open MayFail, innermost last; a failure there
		# skips the steps through that Stage.
		var $may_fail = []
		var $skipping = Bool.False
		var $skip_through = 0
		for step in plan.steps {
			match step {
				Stage(label) => {
					Execute.finish!(mode, $finished)?
					$index = $index + 1
					$may_fail = $may_fail.keep_if(|last| last >= $index)
					$skipping = $skipping and $index <= $skip_through
					$finished = ""
					if !$skipping {
						progress = Output.step(workflow, $index, count, label)
						Output.note!(mode, progress.human, progress.started)?
						$finished = progress.finished
					}
				}
				MayFail(stages) => {
					$may_fail = $may_fail.append($index + stages)
				}
				_ if $skipping => {}
				_ => {
					(snapshots, builds) = match step {
						Snapshot(_) => (Bool.True, Bool.False)
						Run({ output: Artifact(_), .. }) => (Bool.False, Bool.True)
						_ => (Bool.False, Bool.False)
					}
					if snapshots and !$holding {
						Execute.hold!(guard, mode)?
						$holding = Bool.True
					}
					result = Execute.step!(step, layout, mode, options)
					if $holding and (builds or result.is_err()) {
						_ = Workspace.path(guard).delete!()
						$holding = Bool.False
					}
					match (result, $may_fail.last()) {
						(Err(ChildExited(description, code)), Ok(last)) => {
							message = "${description} failed with code ${code.to_str()}; continuing"
							Output.note!(mode, "kai: ${message}", Output.event("note", message, []))?
							$skipping = Bool.True
							$skip_through = last
							$finished = ""
						}
						_ => result?
					}
				}
			}
		}
		if $holding {
			_ = Workspace.path(guard).delete!()
		}
		Execute.finish!(mode, $finished)
	}

	# Close the open workflow step, if any.
	finish! : Output.Mode, Str => Try({}, _)
	finish! = |mode, finished|
		if (finished.is_empty()) Ok({}) else Output.json!(mode, finished)

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
			# Every variable name must be valid, so a name such as `A=B`
			# cannot smuggle a value into the child process's environment.
			Run(run_step) => {
				names = run_step.secrets
					.concat(run_step.removed_environment_variables)
					.concat(run_step.kept_environment_variables)
				if names.all(Execute.variable_name) {
					command(run_step.argv)
				} else {
					Err("names an invalid environment variable")
				}
			}
			PublishLock(_) =>
				match lock {
					OwnsLock => Ok({})
					ReadsLock => Err("only a command that owns the lock publishes it")
				}
			Note(_) | Print(_) | Stage(_) | MayFail(_) | Confirm(_) => Ok({})
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
			Stage(_) | MayFail(_) => Ok({})
			Write(files) => Workspace.stage!(files, layout)
			VerifyPath({ path, argv, stdout, update }) => {
				Workspace.safe_source!(path)?
				(program, args) = match argv {
					[first, .. as rest] => (first, rest)
					[] => return Err(RenderFailed("the plan has an empty command"))
				}
				observed = Cmd.new(OsStr.from_str(program))
					.args(args.map(OsStr.from_str))
					.cwd(Workspace.path(root))
					.run!()?
					.require_success()?
				Stderr.write_bytes!(observed.stderr_bytes)?
				if Str.from_utf8_lossy(observed.stdout_bytes).trim() != stdout {
					return Err(LocalChanged(path, update))
				}
				Ok({})
			}
			CheckSource(path) => Workspace.safe_source!(path)
			Snapshot(snapshot) => Snapshot.snapshot!(snapshot)
			InstallRunner({ destination }) => Workspace.install_runner!(destination)
			Run(run) => {
				process_command = Execute.process_command!(run, root)?
				{ description, output, .. } = run
				match output {
					Inherit => Execute.child!(process_command, description, Inherit)
					Quiet => Execute.child!(process_command, description, Capture)
					Artifact(artifact) =>
						Execute.build!(process_command, description, artifact, mode)
				}
			}
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
				if previous == Present(contents) {
					return Ok({})
				}
				updated = "updated ${layout.lock_path}"
				fields = [("lock", Output.text(layout.lock_path))]
				Output.result!(mode, updated, Output.event("update", updated, fields))
			}
		}
	}

	# Resolve the requested artifact with the planned command: its store path
	# on stdout, only after success.
	build! : Cmd.Command, Str, Plan.Artifact, Output.Mode => Try({}, _)
	build! = |process_command, description, artifact, mode| {
		{ name, label, output: declared } = artifact
		Stderr.line!("building ${name}: ${label} (output ${declared})")?
		output = process_command.stderr(Tee).run!()?
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
			Exited(code) => {
				status = Execute.builder_code(output.stderr_bytes, code)
				Err(ChildExited(description, status))
			}
			Signaled(signal) =>
				Err(ChildExited(description, Execute.signal_status(signal)))
		}
	}

	# Run a child process prepared by `process_command!`, which also sets its
	# working directory to the project root, with inherited stdio; a captured
	# stderr is shown only when the child fails.
	child! = |process_command, description, stderr| {
		ran = process_command.inherit_stdio().stderr(stderr).run!()?
		if ran.status != Exited(0) {
			Stderr.write_bytes!(ran.stderr_bytes)?
		}
		match ran.status {
			Exited(0) => Ok({})
			Exited(code) => Err(ChildExited(description, code))
			Signaled(signal) =>
				Err(ChildExited(description, Execute.signal_status(signal)))
		}
	}

	# The status a shell reports for a process killed by a signal: 128 plus
	# the signal's number, such as 130 for SIGINT (2).
	signal_status = |signal| 128 + signal

	# A Run step's command, run from the project root in kai's environment,
	# with the shell kai was started from as KAI_OPERATOR_SHELL (unset if it
	# had none; backends such as `nix develop` replace SHELL), its secrets set
	# and its removed environment variables, except those kept, unset. Each
	# secret's value comes from the project's `.env`, else kai's environment,
	# and never appears in kai's output, events or errors.
	process_command! = |run, root| {
		{ description, argv, secrets, kept_environment_variables, .. } = run
		removed_environment_variables = run.removed_environment_variables
		(program, args) = match argv {
			[first, .. as rest] => (first, rest)
			[] => return Err(RenderFailed("the plan has an empty command"))
		}
		# Look up each secret's value: `.env` wins over kai's environment, and
		# a secret found in neither stops the run.
		var $secret_values = []
		if !secrets.is_empty() {
			dotenv = match Workspace.path("${root}/.env").read_utf8!() {
				Ok(text) => Execute.dotenv(text)?
				Err(PathErr(NotFound, _)) => []
				Err(err) => return Err(err)
			}
			for name in secrets {
				value = match dotenv.find_first(|(key, _)| key == name) {
					Ok((_, found)) => OsStr.from_str(found)
					Err(_) => {
						missing = |_| MissingSecret(description, name)
						Env.var!(OsStr.from_str(name)).map_err(missing)?
					}
				}
				$secret_values = $secret_values.append((OsStr.from_str(name), value))
			}
		}
		# The child process inherits kai's environment minus every secret
		# and removed environment variable it does not keep, then receives the
		# operator's shell and its own secrets' values.
		operator = OsStr.from_str("KAI_OPERATOR_SHELL")
		removed = secrets
			.concat(removed_environment_variables)
			.keep_if(|name| !kept_environment_variables.contains(name))
			.map(OsStr.from_str)
			.append(operator)
		kept = Env.dict!().keep_if(|(name, _)| !removed.contains(name))
		shell = match Env.var!(OsStr.from_str(Variables.shell.name)) {
			Ok(value) => [(operator, value)]
			Err(_) => []
		}
		Ok(
			Cmd.new(OsStr.from_str(program))
				.args(args.map(OsStr.from_str))
				.cwd(Workspace.path(root))
				.clear_envs()
				.envs(kept)
				.envs(shell)
				.envs($secret_values),
		)
	}

	# A dotenv file's `NAME=value` lines; blank lines and `#` comments are
	# skipped, and one pair of surrounding quotes is removed. Nothing is
	# interpolated. A malformed line is named by number, never its text.
	dotenv : Str -> Try(List((Str, Str)), [InvalidDotenv(U64)])
	dotenv = |text| {
		var $pairs = []
		var $number = 0
		for line in text.split_on("\n") {
			$number = $number + 1
			trimmed = line.trim()
			if !trimmed.is_empty() and !trimmed.starts_with("#") {
				(name, value) = match trimmed.split_first("=") {
					Ok({ before, after }) => (before.trim(), after.trim())
					Err(_) => return Err(InvalidDotenv($number))
				}
				if !Execute.variable_name(name) {
					return Err(InvalidDotenv($number))
				}
				quotes = ['"', '\'']
				unquoted = match value.to_utf8() {
					[first, .. as inner, last] if first == last and quotes.contains(first) =>
						Str.from_utf8_lossy(inner)
					_ => value
				}
				$pairs = $pairs.append((name, unquoted))
			}
		}
		Ok($pairs)
	}

	# An environment variable name: a letter or _, then letters, digits or _.
	variable_name : Str -> Bool
	variable_name = |name| {
		letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_'
		match name.to_utf8() {
			[first, .. as rest] =>
				letter(first) and rest.all(|b| letter(b) or (b >= '0' and b <= '9'))
			[] => Bool.False
		}
	}

	# nix build and guix build exit 1 when a build fails; their report's
	# "builder … failed with exit code N" names the build command's own
	# status. Echoed build log lines are indented under "> " and never match.
	builder_code : List(U8), I32 -> I32
	builder_code = |stderr, code| {
		reports = ["error: builder for ", "Reason: builder failed ", "builder for "]
		var $found = code
		for line in Str.from_utf8_lossy(stderr).split_on("\n") {
			if reports.any(|report| line.trim().starts_with(report)) {
				match line.split_first("failed with exit code ") {
					Ok(parts) => {
						$found = Execute.leading_number(parts.after).ok_or($found)
					}
					Err(_) => {}
				}
			}
		}
		$found
	}

	leading_number : Str -> Try(I32, _)
	leading_number = |text| {
		var $digits = []
		var $reading = Bool.True
		for byte in text.to_utf8() {
			$reading = $reading and byte >= '0' and byte <= '9'
			if $reading {
				$digits = $digits.append(byte)
			}
		}
		I32.from_str(Str.from_utf8_lossy($digits))
	}

	# A child's status becomes kai's own; statuses a process cannot exit with,
	# such as a signal report, become a generic failure.
	exit_code : I32 -> I32
	exit_code = |code| if (code > 0 and code < 256) code else 1
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

run : List(Str), List(Str), List(Str), List(Str) -> Plan.Step
run = |argv, secrets, removed_environment_variables, kept_environment_variables|
	Run({
		description: "t",
		argv,
		output: Inherit,
		secrets,
		removed_environment_variables,
		kept_environment_variables,
	})

validated : List(Plan.Step) -> Try({}, [UnsafePlan(Str)])
validated = |steps|
	Execute.validate(Plan.{ steps, next: Done }, layout, ReadsLock)

# A build's steps pass: files beneath the generated root, verified project
# sources, the snapshot and runner in the workspace, exact argv.
expect
	validated([
		Stage("build app"),
		VerifyPath({
			path: "/p/vendor",
			argv: ["nix", "hash"],
			stdout: "x",
			update: "kai update vendor",
		}),
		Snapshot({
			root: "/p",
			destination: "/p/.kai/snapshot",
			exclude: [],
			files: All,
			store: "/nix/store",
		}),
		InstallRunner({ destination: "/p/.kai/build-runner" }),
		Write([{ path: "/p/.kai/generated/flake.nix", contents: "" }]),
		run(["/bin/nix", "build"], ["TOKEN"], ["OTHER"], ["VERSION"]),
		Note("n"),
	])
		== Ok({})

# Each unsafe or unsupported step refuses the whole plan.
expect [
	Write([{ path: "/p/.kai/lock.json", contents: "" }]),
	Write([{ path: "/p/.kai/generated/../lock.json", contents: "" }]),
	Write([{ path: "/p/flake.nix", contents: "" }]),
	VerifyPath({ path: "/etc", argv: ["nix"], stdout: "", update: "" }),
	VerifyPath({ path: "/p/../etc", argv: ["nix"], stdout: "", update: "" }),
	VerifyPath({ path: "/p/src", argv: [], stdout: "", update: "" }),
	Snapshot({
		root: "/p",
		destination: "/p/src",
		exclude: [],
		files: All,
		store: "/nix/store",
	}),
	InstallRunner({ destination: "/tmp/runner" }),
	run([], [], [], []),
	run([""], [], [], []),
	run(["-c"], [], [], []),
	run(["bin/sh"], [], [], []),
	run(["sh"], ["A=B"], [], []),
	run(["sh"], [], ["1A"], []),
	run(["sh"], [], [], ["A=B"]),
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

# A failed build's status is its builder's, from nix's or guix's report.
expect {
	old = "error: builder for '/nix/store/x.drv' failed with exit code 3;\n"
	new = "error: Cannot build 'x'.\n  Reason: builder failed with exit code 5.\n"
	log = "  > builder failed with exit code 9\n"
	guix = "builder for `/gnu/store/x.drv' failed with exit code 4\n"
	[(old, 3), (new.concat(log), 5), (guix, 4), ("error: no flake\n", 1)]
		.all(|(report, exit)| Execute.builder_code(report.to_utf8(), 1) == exit)
}

# A dotenv file gives exact values: comments and blank lines are skipped, one
# pair of quotes is removed, and a malformed line is named by number only.
expect [
	(
		"# c\n\nA=1\n B = \"two words\" \r\nC='x=$y'\nD=\n",
		Ok([("A", "1"), ("B", "two words"), ("C", "x=$y"), ("D", "")]),
	),
	("A=1\nsecret value\n", Err(InvalidDotenv(2))),
	("1A=x\n", Err(InvalidDotenv(1))),
].all(|(text, expected)| Execute.dotenv(text) == expected)
