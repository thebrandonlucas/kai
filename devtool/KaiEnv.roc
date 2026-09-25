# Run a built `kai shell` and `kai run` against real Nix on a copy of
# examples/overlays: overlay stacks apply in order only to environments that
# select them, Extend applies the parent's stack first, and shells aliasing
# different environments differ. One update serves every request unchanged.
import pf.Cmd
import pf.Path
import pf.Stdout

import KaiUpdate

KaiEnv := [].{
	run! = |binary| {
		(kai, project) = KaiUpdate.fixture!(binary, "overlays", ["overlays"])?
		result = KaiEnv.run_in!(kai, project)
		Path.delete_all!(project)?
		result
	}

	# The base overlay replaces fixture-tool and patch wraps the earlier one,
	# so reversing the stack drops patch.
	expected = [
		{ shell: "base", output: "base\n" },
		{ shell: "forward", output: "patch:base\n" },
		{ shell: "reversed", output: "base\n" },
		{ shell: "default", output: "patch:base\n" },
	]

	run_in! = |kai, project| {
		lock = Path.join(project, ".kai/lock.json")
		kai! = |args| Cmd.new(Path.to_os_str(kai)).args_str(args).cwd(project)
			.exec_output!()
		_ = kai!(["update"])?
		published = Path.read_bytes!(lock)?
		for case in KaiEnv.expected {
			output = kai!(["shell", case.shell, "--", "fixture-tool"])?.stdout_utf8
			if output != case.output {
				return Err(WrongOverlayStack(case.shell, output))
			}
		}
		# Declared overlays do not leak into an environment that selects none.
		match kai!(["shell", "plain", "--", "fixture-tool"]) {
			Err(NonZeroExitCode({ exit_code, stderr_utf8_lossy, .. })) if exit_code == 1
				and stderr_utf8_lossy.contains("fixtureTool") => {}
			other => return Err(UnselectedOverlayApplied(Str.inspect(other)))
		}
		# The child's own tool runs beside the inherited, overlaid one.
		greeting = kai!(["run", "greet", "--", "from dev"])?.stdout_utf8
		if greeting != "from dev\n" {
			return Err(WrongTaskOutput(greeting))
		}
		if Path.read_bytes!(lock)? != published {
			return Err(LockChanged)
		}
		Stdout.line!("kai kept overlay order, scope and inheritance per environment")
	}
}
