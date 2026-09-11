# A small API to check expected results against actual results for given
# implementations, used to make test inputs/outputs more self-documenting.
import kai.Plugin

Check := [].{
	Invocation : {
		args : List(Str),
		arch : Plugin.HostArch,
		kaifile : Str,
		os : Plugin.HostOs,
		workspace_root : Str,
	}
	Write : { contents : Str, path : Str }
	WriteOutcome : [
		ExpectedOneWriteFile({ count : U64, path : Str }),
		PlanRegistryFailed(Plugin.Error),
		PlannedWrite(Write),
	]
	WriteComparison : { actual : WriteOutcome, expected : WriteOutcome }
	compare_planned_write :
		List(Plugin.Definition), Invocation, Write -> WriteComparison
	compare_planned_write = |registry, invocation, expected| {
		actual = match Plugin.plan_registry(
			registry,
			invocation.kaifile,
			invocation.args,
			invocation.os,
			invocation.arch,
			invocation.workspace_root,
		) {
			Ok(plan) => {
				matching_writes = plan.steps.keep_if(
					|step|
						match step {
							WriteFile({ contents: _, path }) => path == expected.path
							_ => Bool.False
						},
				)
				match matching_writes {
					[WriteFile(write)] => PlannedWrite(write)
					_ => ExpectedOneWriteFile({
						count: matching_writes.len(),
						path: expected.path,
					})
				}
			}
			Err(problem) => PlanRegistryFailed(problem)
		}
		{ actual, expected: PlannedWrite(expected) }
	}
}
