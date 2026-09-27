# Execute a shell, task, build or workflow request: select its backend, obtain
# its whole pure plan (for Nix after reading the lock authority) and run the
# steps in order. Nothing here writes the lock.
import pf.Cmd
import pf.Stderr
import pf.Stdout

import api.Layout
import api.Plan
import ir.Ir
import ir.Request
import nix.NixBackend
import nix.Locks
import guix.GuixBackend

import Output
import Selection
import Snapshot
import Update
import Workspace

Execute := [].{
	# Probe only the backends the decision can depend on: Guix only when Nix
	# is not both fitting and usable, because Auto prefers Nix.
	select! :
		Ir, Request, Selection.BackendChoice, Str, Output.Mode => Try({}, _)
	select! = |ir, request, choice, root, mode| {
		fits = Selection.fitting(choice, request, ir)
		nix = if fits.contains(Nix) Execute.probe!("nix") else Unchecked
		guix = match nix {
			Usable => Unchecked
			_ => if fits.contains(Guix) Execute.probe!("guix") else Unchecked
		}
		observed = { nix, guix }
		backend = Selection.resolve(choice, request, ir, observed)?
		why = Selection.explain(choice, request, ir, observed, backend)
		Output.note!(
			mode,
			"kai: ${why}",
			Output.event(
				"backend",
				why,
				[("backend", Output.text(Selection.name(backend)))],
			),
		)?
		layout = Workspace.locate!(root)?
		match backend {
			Nix => Execute.request!(ir, request, layout, mode)
			Guix => {
				plan = GuixBackend.steps(ir, request)
					.map_err(|message| GuixFailed(message))?
				Execute.run!(plan, request, layout, mode)
			}
		}
	}

	# A bounded, side-effect-free check that an executable runs at all.
	probe! : Str => Selection.Probe
	probe! = |program| {
		version = Cmd.new_str(program).args_str(["--version"]).timeout_ms(10000)
		match version.run!() {
			Ok({ status: Exited(0), .. }) => Usable
			Ok({ status: Exited(code), .. }) =>
				Unusable("`${program} --version` exited with code ${code.to_str()}")
			Ok({ status: Signaled(signal), .. }) =>
				Unusable("`${program} --version` got signal ${signal.to_str()}")
			Err(IO(NotFound)) => Missing
			Err(Timeout(_)) => Unusable("`${program} --version` timed out")
			Err(err) => Unusable(Str.inspect(err))
		}
	}

	# The whole plan, every workflow step included, is checked before the
	# first effect.
	request! : Ir, Request, Layout, Output.Mode => Try({}, _)
	request! = |ir, request, layout, mode| {
		target = Update.target!()?
		NixBackend.preflight(ir, request, target, layout)
			.map_err(|message| RenderFailed(message))?
		text = match Update.observe!(layout.lock_path)? {
			Present(bytes) => Str.from_utf8(bytes)
				.map_err(|_| BadLock(layout.lock_path, "not UTF-8"))?
			Absent => return Err(NoLock(layout.lock_path))
		}
		locks = Locks.decode(text)
			.map_err(|message| BadLock(layout.lock_path, message))?
		planned = NixBackend.plan(ir, request, target, layout, locks)
			.map_err(|message| RenderFailed(message))?
		plan = NixBackend.steps(planned, request)
			.map_err(|message| RenderFailed(message))?
		Execute.run!(plan, request, layout, mode)
	}

	# Run the steps in order; the first failure stops the plan. Each Stage
	# opens a numbered workflow step that the next Stage or the end closes.
	run! : Plan, Request, Layout, Output.Mode => Try({}, _)
	run! = |plan, request, layout, mode| {
		if plan.steps.any(Execute.uses_workspace) {
			Workspace.prepare!(layout)?
		}
		workflow = match request {
			Request.Workflow(name) => name
			_ => ""
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
				_ => Execute.step!(step, layout, mode)?
			}
		}
		Execute.finish!(mode, $finished)
	}

	# Close the open workflow step, if any.
	finish! : Output.Mode, Str => Try({}, _)
	finish! = |mode, finished|
		if finished.is_empty() Ok({}) else Output.json!(mode, finished)

	uses_workspace : Plan.Step -> Bool
	uses_workspace = |step|
		match step {
			Write(_) | Snapshot(_) | InstallRunner(_) => Bool.True
			_ => Bool.False
		}

	# One step's effect. Children run from the project root; a failing child
	# stops the plan.
	step! : Plan.Step, Layout, Output.Mode => Try({}, _)
	step! = |step, layout, mode| {
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
			Snapshot(snapshot) => Snapshot.snapshot!(snapshot)
			InstallRunner({ destination }) => Workspace.install_runner!(destination)
			Run({ what, argv, output: Inherit }) => Execute.child!(argv, what, root)
			Run({ what, argv, output: Artifact(artifact) }) =>
				Execute.build!(argv, what, artifact, root, mode)
			Confirm(_) => Err(RenderFailed("this kai cannot confirm steps yet"))
			PublishLock(_) => Err(RenderFailed("this kai cannot publish a lock yet"))
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
