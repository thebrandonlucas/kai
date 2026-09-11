# A small API to check expected results against actual results for given
# implementations, used to make test inputs/outputs more self-documenting.
import kai.Plugin

Check := [].{
	Registry : List(Plugin.Definition)
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
	WritesAtPathExpectation : { contents : List(Str), path : Str }
	WritesAtPathOutcome : [
		PlanRegistryFailed(Plugin.Error),
		PlannedWritesAtPath(WritesAtPathExpectation),
	]
	WritesAtPathComparison : {
		actual : WritesAtPathOutcome,
		expected : WritesAtPathOutcome,
	}
	PlannedStepOutcome : [
		PlanRegistryFailed(Plugin.Error),
		PlannedStepFound,
		PlannedStepMissing,
	]
	PlannedStepComparison : {
		actual : PlannedStepOutcome,
		expected : PlannedStepOutcome,
	}
	PlanningErrorOutcome : [
		PlanRegistryFailed(Plugin.Error),
		PlanRegistrySucceeded,
	]
	PlanningErrorComparison : {
		actual : PlanningErrorOutcome,
		expected : PlanningErrorOutcome,
	}
	compare_planned_write :
		Registry, Invocation, Write -> WriteComparison
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

	compare_planned_writes_at_path :
		Registry, Invocation, WritesAtPathExpectation -> WritesAtPathComparison
	compare_planned_writes_at_path = |registry, invocation, expected| {
		actual = match Plugin.plan_registry(
			registry,
			invocation.kaifile,
			invocation.args,
			invocation.os,
			invocation.arch,
			invocation.workspace_root,
		) {
			Ok(plan) => {
				matching_contents = plan.steps.keep_if(
					|step|
						match step {
							WriteFile({ contents: _, path }) => path == expected.path
							_ => Bool.False
						},
				).map(
					|step|
						match step {
							WriteFile({ contents: write_contents, path: _ }) => write_contents
							_ => "unreachable non-write step"
						},
				)
				PlannedWritesAtPath({
					contents: matching_contents,
					path: expected.path,
				})
			}
			Err(problem) => PlanRegistryFailed(problem)
		}
		{ actual, expected: PlannedWritesAtPath(expected) }
	}

	compare_planned_step :
		Registry, Invocation, Plugin.ExecutionStep -> PlannedStepComparison
	compare_planned_step = |registry, invocation, expected| {
		actual = match Plugin.plan_registry(
			registry,
			invocation.kaifile,
			invocation.args,
			invocation.os,
			invocation.arch,
			invocation.workspace_root,
		) {
			Ok(plan) => {
				found = List.any(
					plan.steps,
					|step|
						match (step, expected) {
							(PrintLine(actual_line), PrintLine(expected_line)) =>
								actual_line == expected_line
							(RunProgram(actual_run), RunProgram(expected_run)) =>
								actual_run.arguments == expected_run.arguments and
									actual_run.program == expected_run.program
							(WriteFile(actual_write), WriteFile(expected_write)) =>
								actual_write.contents == expected_write.contents and
									actual_write.path == expected_write.path
							_ => Bool.False
						},
				)
				if found PlannedStepFound else PlannedStepMissing
			}
			Err(problem) => PlanRegistryFailed(problem)
		}
		{ actual, expected: PlannedStepFound }
	}

	compare_planning_error :
		Registry, Invocation, Plugin.Error -> PlanningErrorComparison
	compare_planning_error = |registry, invocation, expected| {
		actual = match Plugin.plan_registry(
			registry,
			invocation.kaifile,
			invocation.args,
			invocation.os,
			invocation.arch,
			invocation.workspace_root,
		) {
			Ok(_) => PlanRegistrySucceeded
			Err(problem) => PlanRegistryFailed(problem)
		}
		{ actual, expected: PlanRegistryFailed(expected) }
	}
}
