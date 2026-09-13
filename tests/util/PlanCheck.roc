# A small API for comparing plugin planning inputs, invocations, and expected
# outputs while keeping test cases declarative.
import kai.PlanningError
import kai.Plugin

PlanCheck := [].{
	Input : {
		definitions : List(Plugin.Definition),
		host : Plugin.Host,
		kaifile : Str,
		workspace_root : Str,
	}
	Invocation : List(Str)
	ExpectedOutcome : [FailsWith(Plugin.Error), Succeeds(List(PlanExpectation))]
	PlanExpectation : [
		ContainsArtifact(Plugin.Artifact),
		ContainsRunProgramArguments({ arguments : List(Str), program : Str }),
		ContainsStep(Plugin.ExecutionStep),
		ContainsStepsInOrder(List(Plugin.ExecutionStep)),
		WritesAtPathExactly({ contents : List(Str), path : Str }),
		WritesExactly({ contents : Str, path : Str }),
	]

	plan : Input, Invocation, ExpectedOutcome -> Bool
	plan = |input, invocation, expected|
		match Plugin.plan_registry(
			input.definitions,
			input.kaifile,
			"Kaifile",
			invocation,
			input.host.os,
			input.host.arch,
			input.workspace_root,
		) {
			Ok(actual) =>
				match expected {
					Succeeds(expectations) =>
						List.all(
							expectations,
							|expectation| PlanCheck.expectation_matches(actual, expectation),
						)
					FailsWith(_) => Bool.False
				}
			Err(actual) =>
				match expected {
					FailsWith(expected_error) => actual == expected_error
					Succeeds(_) => Bool.False
				}
			}

	error : Input, Invocation, Str -> Bool
	error = |input, invocation, expected|
		match Plugin.plan_registry(
			input.definitions,
			input.kaifile,
			"Kaifile",
			invocation,
			input.host.os,
			input.host.arch,
			input.workspace_root,
		) {
			Err(PlanningFailed(diagnostic)) =>
				PlanningError.planning_error(
					"Kaifile",
					input.kaifile,
					input.definitions,
					diagnostic,
				) == expected
			_ => Bool.False
		}

	expectation_matches : Plugin.ExecutionPlan, PlanExpectation -> Bool
	expectation_matches = |actual_plan, expectation|
		match expectation {
			ContainsArtifact(expected) =>
				List.any(
					actual_plan.artifacts,
					|actual| PlanCheck.artifacts_equal(actual, expected),
				)
			ContainsRunProgramArguments(expected) =>
				List.any(
					actual_plan.steps,
					|step|
						match step {
							RunProgram(actual) =>
								actual.program == expected.program and
									List.all(
										expected.arguments,
										|argument| actual.arguments.contains(argument),
									)
							_ => Bool.False
						},
				)
			ContainsStep(expected) =>
				List.any(
					actual_plan.steps,
					|actual| PlanCheck.steps_equal(actual, expected),
				)
			ContainsStepsInOrder(expected) =>
				PlanCheck.contains_steps_in_order(actual_plan.steps, expected)
			WritesAtPathExactly(expected) => {
				contents = actual_plan.steps.keep_if(
					|step|
						match step {
							WriteFile(write) => write.path == expected.path
							_ => Bool.False
						},
				).map(
					|step|
						match step {
							WriteFile(write) => write.contents
							_ => "unreachable non-write step"
						},
				)
				contents == expected.contents
			}
			WritesExactly(expected) => {
				matching = actual_plan.steps.keep_if(
					|step|
						match step {
							WriteFile(write) => write.path == expected.path
							_ => Bool.False
						},
				)
				match matching {
					[WriteFile(actual)] =>
						actual.contents == expected.contents and
							actual.path == expected.path
					_ => Bool.False
				}
			}
		}

	contains_steps_in_order :
		List(Plugin.ExecutionStep), List(Plugin.ExecutionStep) -> Bool
	contains_steps_in_order = |actual, expected|
		match expected {
			[] => Bool.True
			[expected_first, .. as expected_rest] =>
				match actual {
					[] => Bool.False
					[actual_first, .. as actual_rest] =>
						if PlanCheck.steps_equal(actual_first, expected_first) {
							PlanCheck.contains_steps_in_order(actual_rest, expected_rest)
						} else {
							PlanCheck.contains_steps_in_order(actual_rest, expected)
						}
					}
			}

	steps_equal : Plugin.ExecutionStep, Plugin.ExecutionStep -> Bool
	steps_equal = |actual, expected|
		match (actual, expected) {
			(Confirm(actual_message), Confirm(expected_message)) =>
				actual_message == expected_message
			(PrintLine(actual_line), PrintLine(expected_line)) =>
				actual_line == expected_line
			(RunProgram(actual_run), RunProgram(expected_run)) =>
				actual_run.arguments == expected_run.arguments and
					actual_run.program == expected_run.program
			(WriteFile(actual_write), WriteFile(expected_write)) =>
				actual_write.contents == expected_write.contents and
					actual_write.path == expected_write.path
			_ => Bool.False
		}

	artifact_attributes_equal :
		List(Plugin.ArtifactAttribute), List(Plugin.ArtifactAttribute) -> Bool
	artifact_attributes_equal = |actual, expected|
		match (actual, expected) {
			([], []) => Bool.True
			([actual_first, .. as actual_rest], [expected_first, .. as expected_rest]) =>
				actual_first.key == expected_first.key and
					actual_first.value == expected_first.value and
						PlanCheck.artifact_attributes_equal(actual_rest, expected_rest)
			_ => Bool.False
		}

	artifacts_equal : Plugin.Artifact, Plugin.Artifact -> Bool
	artifacts_equal = |actual, expected|
		PlanCheck.artifact_attributes_equal(
			actual.attributes,
			expected.attributes,
		) and
			actual.kind == expected.kind and
				actual.name == expected.name and
					actual.path == expected.path
}
