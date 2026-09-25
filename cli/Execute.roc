# Execute a shell or task request: read the lock authority, obtain the whole
# pure plan, then run its steps in order. Nothing here writes the lock.
import pf.Cmd
import pf.Stderr

import ir.Ir
import ir.Layout
import ir.Plan
import ir.Request
import nix.NixBackend
import nix.Locks

import Update
import Workspace

Execute := [].{
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

	# Verify local pins, stage generated files, then run the argv from the
	# project root with inherited stdio. A failing child stops the plan.
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
				# Snapshots only materialize builds, which kai cannot run yet.
				Snapshot(_) => return Err(Unsupported("snapshot operation"))
			}
		}
		Workspace.stage!(step.files, layout)?
		match step.argv {
			[program, .. as args] => {
				code = Cmd.new_str(program)
					.args_str(args)
					.cwd(Workspace.path(layout.project_root))
					.exec_exit_code!()?
				if code == 0 Ok({}) else Err(ChildExited(step.action, code))
			}
			[] => Ok({})
		}
	}

	# A child's status becomes kai's own; statuses a process cannot exit with,
	# such as a signal report, become a generic failure.
	exit_code : I32 -> I32
	exit_code = |code| if code > 0 and code < 256 code else 1
}

# A failing child's status is kept rather than collapsed to 1.
expect [(7, 7), (1, 1), (255, 255), (256, 1), (-1, 1), (0, 1)]
	.all(|(code, exit)| Execute.exit_code(code) == exit)
