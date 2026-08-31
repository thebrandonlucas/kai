# An implementation for running workflows via nix
import parser.Fields
import kai.Plugin
import backends.Nix as NixBackend
import schemas.Workflow as WorkflowCommand

WorkflowNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: WorkflowCommand.command.name,
		plan: WorkflowNix.plan,
		validator: NoValidation,
	}

	plan :
		Plugin.ImplementationInput ->
			Try(
				Plugin.CommandPlan,
				Plugin.ImplementationDiagnostic,
			)
	plan = |input| {
		steps = Fields.get_strings(input.command_fields, "steps") ? |_| {
			byte_offset: None,
			message: "validated workflow configuration is missing 'steps'",
		}
		if steps.is_empty() {
			Err({
				byte_offset: None,
				message: "workflow must contain at least one step",
			})
		} else {
			prerequisite_commands = WorkflowNix.parse_steps(steps)?
			Ok(
				Plugin.CommandPlan.{
					artifacts: [],
					prerequisite_commands,
					requested_packages: [],
					steps: [],
				},
			)
		}
	}

	parse_steps :
		List(Str) ->
			Try(
				List(Plugin.PrerequisiteCommand),
				Plugin.ImplementationDiagnostic,
			)
	parse_steps = |steps| WorkflowNix.parse_steps_from(steps, 1)

	parse_steps_from :
		List(Str),
		U64 ->
			Try(
				List(Plugin.PrerequisiteCommand),
				Plugin.ImplementationDiagnostic,
			)
	parse_steps_from = |steps, index|
		match steps {
			[] => Ok([])
			[first, .. as rest] => {
				prerequisite = WorkflowNix.parse_step(first) ? |_|
					WorkflowNix.invalid_step(index, first)
				remaining = WorkflowNix.parse_steps_from(rest, index + 1)?
				Ok([prerequisite].concat(remaining))
			}
		}

	parse_step : Str -> Try(Plugin.PrerequisiteCommand, [InvalidWorkflowStep])
	parse_step = |step|
		match WorkflowNix.words(step) {
			[] => Err(InvalidWorkflowStep)
			arguments => Ok({
				arguments,
				description: "workflow: ${Str.join_with(arguments, " ")}",
			})
		}

	invalid_step : U64, Str -> Plugin.ImplementationDiagnostic
	invalid_step = |index, step| {
		byte_offset: None,
		message: Str.join_with(
			[
				"workflow step ${U64.to_str(index)} is invalid: '${step}'; ",
				"expected a command and optional arguments",
			],
			"",
		),
	}

	words : Str -> List(Str)
	words = |text| WorkflowNix.collect_words(text.to_utf8(), 0, [])

	collect_words : List(U8), U64, List(Str) -> List(Str)
	collect_words = |bytes, index, collected| {
		start = WorkflowNix.skip_whitespace(bytes, index)
		if start >= bytes.len() {
			collected
		} else {
			end = WorkflowNix.find_word_end(bytes, start)
			word = Str.from_utf8(bytes.sublist({ start, len: end - start })) ?? ""
			WorkflowNix.collect_words(bytes, end, collected.append(word))
		}
	}

	skip_whitespace : List(U8), U64 -> U64
	skip_whitespace = |bytes, index|
		if index < bytes.len() and Fields.is_whitespace(bytes.get(index) ?? 0) {
			WorkflowNix.skip_whitespace(bytes, index + 1)
		} else {
			index
		}

	find_word_end : List(U8), U64 -> U64
	find_word_end = |bytes, index|
		if index < bytes.len() and !Fields.is_whitespace(bytes.get(index) ?? 0) {
			WorkflowNix.find_word_end(bytes, index + 1)
		} else {
			index
		}

}
