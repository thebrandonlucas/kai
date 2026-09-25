# Execute a shell, task or build request: select its backend, then for Nix
# read the lock authority, obtain the whole pure plan and run its steps in
# order, or run one Guix shell. Nothing here writes the lock.
import pf.Cmd
import pf.Stderr
import pf.Stdout

import ir.Ir
import ir.Layout
import ir.Plan
import ir.Request
import nix.NixBackend
import nix.Locks
import guix.GuixBackend

import Selection
import Snapshot
import Update
import Workspace

Execute := [].{
	# Probe only the backends the decision can depend on: Guix only when Nix
	# is not both fitting and usable, because Auto prefers Nix.
	select! : Ir, Request, Selection.BackendChoice, Str => Try({}, _)
	select! = |ir, request, choice, root| {
		fits = Selection.fitting(choice, request, ir)
		nix = if fits.contains(Nix) Execute.probe!("nix") else Unchecked
		guix = match nix {
			Usable => Unchecked
			_ => if fits.contains(Guix) Execute.probe!("guix") else Unchecked
		}
		observed = { nix, guix }
		backend = Selection.resolve(choice, request, ir, observed)?
		Stderr.line!(
			"kai: ${Selection.explain(choice, request, ir, observed, backend)}",
		)?
		match backend {
			Nix => Execute.request!(ir, request, Workspace.locate!(root)?)
			Guix => Execute.guix!(ir, request, root)
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

	# Guix shells use the installed channels and never touch the workspace.
	guix! : Ir, Request, Str => Try({}, _)
	guix! = |ir, request, root| {
		argv = GuixBackend.plan(ir, request).map_err(|message| GuixFailed(message))?
		Stderr.line!(
			"kai: this Guix shell uses the installed Guix channels and is not "
				.concat("pinned by Kai's lock"),
		)?
		action = match request {
			Request.Shell(name, _) => Shell(name)
			_ => Generate
		}
		Execute.child!(argv, action, root)
	}

	request! : Ir, Request, Layout => Try({}, _)
	request! = |ir, request, layout| {
		NixBackend.preflight(ir, request, Update.target, layout)
			.map_err(|message| RenderFailed(message))?
		text = match Update.observe!(layout.lock_path)? {
			Present(bytes) => Str.from_utf8(bytes)
				.map_err(|_| BadLock(layout.lock_path, "not UTF-8"))?
			Absent => return Err(NoLock(layout.lock_path))
		}
		locks = Locks.decode(text)
			.map_err(|message| BadLock(layout.lock_path, message))?
		plan = NixBackend.plan(ir, request, Update.target, layout, locks)
			.map_err(|message| RenderFailed(message))?
		Workspace.prepare!(layout)?
		for step in plan.steps {
			Execute.step!(step, layout)?
		}
		Ok({})
	}

	# Verify local pins, snapshot the project and install the runner for a
	# build, stage generated files, then run the argv from the project root. A
	# failing child stops the plan.
	step! : Plan.Step, Layout => Try({}, _)
	step! = |step, layout| {
		for operation in step.operations {
			match operation {
				VerifyLocal({ path, nar_hash }) => {
					Workspace.safe_source!(path)?
					observed = Cmd.new_str("nix")
						.args_str(["hash", "path", "--sri", path])
						.cwd(Workspace.path(layout.project_root))
						.exec_output!()?
					Stderr.write!(observed.stderr_utf8_lossy)?
					if observed.stdout_utf8.trim() != nar_hash {
						return Err(LocalChanged(path))
					}
				}
				Snapshot(snapshot) => Snapshot.snapshot!(snapshot)?
				InstallRunner({ destination }) =>
					Workspace.install_runner!(destination)?
				}
		}
		Workspace.stage!(step.files, layout)?
		match step.action {
			Build(name) => Execute.build!(step, name, layout.project_root)
			_ => Execute.child!(step.argv, step.action, layout.project_root)
		}
	}

	# Resolve the requested artifact with the planned command: its store path
	# on stdout, only after success. Dependency metadata stays descriptive.
	build! : Plan.Step, Str, Str => Try({}, _)
	build! = |step, name, root| {
		for artifact in step.artifacts {
			Stderr.line!(
				"building ${artifact.name}: ${artifact.installable} "
					.concat("(output ${artifact.output})"),
			)?
		}
		artifact = step.artifacts.find_first(|a| a.name == name)
			.map_err(|_| RenderFailed("the plan has no artifact ${name}"))?
		(program, args) = match step.argv {
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
				Stdout.write_bytes!(output.stdout_bytes)?
				path = Str.from_utf8_lossy(output.stdout_bytes).trim()
				Stderr.line!("built ${name}: ${artifact.installable} -> ${path}")
			}
			Exited(code) => Err(ChildExited(Build(name), code))
			Signaled(signal) => Err(ChildExited(Build(name), 128 + signal))
		}
	}

	# Run argv from the project root with inherited stdio.
	child! = |argv, action, root|
		match argv {
			[program, .. as args] => {
				code = Cmd.new_str(program)
					.args_str(args)
					.cwd(Workspace.path(root))
					.exec_exit_code!()?
				if code == 0 Ok({}) else Err(ChildExited(action, code))
			}
			[] => Ok({})
		}

	# A child's status becomes kai's own; statuses a process cannot exit with,
	# such as a signal report, become a generic failure.
	exit_code : I32 -> I32
	exit_code = |code| if code > 0 and code < 256 code else 1
}

# A failing child's status is kept rather than collapsed to 1.
expect [(7, 7), (1, 1), (255, 255), (256, 1), (-1, 1), (0, 1)]
	.all(|(code, exit)| Execute.exit_code(code) == exit)
