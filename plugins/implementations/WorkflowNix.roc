import parser.Body
import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Workflow as WorkflowCommand

WorkflowNix := [].{
	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: [],
		backend: NixBackend.backend.name,
		command: WorkflowCommand.command.name,
		renderer: WorkflowNix.renderer,
	}

	ci_implementation : PluginApi.Implementation
	ci_implementation = PluginApi.Implementation.{
		actions: [],
		backend: NixBackend.backend.name,
		command: WorkflowCommand.ci_command.name,
		renderer: WorkflowNix.renderer,
	}

	renderer : PluginApi.Renderer
	renderer = |context| {
		steps = Body.get_strings(context.config, "steps") ? |_| {
			byte_offset: None,
			message: "validated workflow configuration is missing 'steps'",
		}
		if steps.is_empty() {
			Err({ byte_offset: None, message: "workflow must contain at least one step" })
		} else {
			requests = WorkflowNix.parse_steps(steps)?
			Ok(
				PluginApi.RenderResult.{
					actions: [],
					outputs: [],
					requests,
					requested_packages: [],
				},
			)
		}
	}

	parse_steps : List(Str) -> Try(List(PluginApi.PlanRequest), PluginApi.RendererDiagnostic)
	parse_steps = |steps| WorkflowNix.parse_steps_from(steps, 1)

	parse_steps_from : List(Str), U64 -> Try(List(PluginApi.PlanRequest), PluginApi.RendererDiagnostic)
	parse_steps_from = |steps, index|
		match steps {
			[] => Ok([])
			[first, .. as rest] => {
				request = WorkflowNix.parse_step(first) ? |_| WorkflowNix.invalid_step(index, first)
				remaining = WorkflowNix.parse_steps_from(rest, index + 1)?
				Ok([request].concat(remaining))
			}
		}

	parse_step : Str -> Try(PluginApi.PlanRequest, [InvalidWorkflowStep])
	parse_step = |step|
		match WorkflowNix.words(step) {
			[operation, name] if operation == "run" or operation == "build" => Ok({
				args: [operation, name],
				status: "workflow: ${operation} ${name}",
			})
			_ => Err(InvalidWorkflowStep)
		}

	invalid_step : U64, Str -> PluginApi.RendererDiagnostic
	invalid_step = |index, step| {
		byte_offset: None,
		message: "workflow step ${U64.to_str(index)} is invalid: '${step}'; expected 'run <name>' or 'build <name>'",
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
		if index < bytes.len() and Body.is_whitespace(bytes.get(index) ?? 0) {
			WorkflowNix.skip_whitespace(bytes, index + 1)
		} else {
			index
		}

	find_word_end : List(U8), U64 -> U64
	find_word_end = |bytes, index|
		if index < bytes.len() and !Body.is_whitespace(bytes.get(index) ?? 0) {
			WorkflowNix.find_word_end(bytes, index + 1)
		} else {
			index
		}

}

# -- TESTS --

step_cases = [
	{
		expected: Ok({ args: ["run", "test"], status: "workflow: run test" }),
		step: "run test",
	},
	{
		expected: Ok({ args: ["build", "app"], status: "workflow: build app" }),
		step: " \tbuild\n  app\r ",
	},
	{
		expected: Ok({ args: ["run", "test:unit"], status: "workflow: run test:unit" }),
		step: "run test:unit",
	},
	{ expected: Err(InvalidWorkflowStep), step: "" },
	{ expected: Err(InvalidWorkflowStep), step: "run" },
	{ expected: Err(InvalidWorkflowStep), step: "run test extra" },
	{ expected: Err(InvalidWorkflowStep), step: "shell dev" },
	{ expected: Err(InvalidWorkflowStep), step: "workflow ci" },
	{ expected: Err(InvalidWorkflowStep), step: "deploy production" },
	{ expected: Ok({ args: ["run", "test;"], status: "workflow: run test;" }), step: "run test;" },
	{ expected: Err(InvalidWorkflowStep), step: "run test && echo bad" },
	{ expected: Err(InvalidWorkflowStep), step: "build app | cat" },
]

expect List.all(step_cases, |case| WorkflowNix.parse_step(case.step) == case.expected)

expect WorkflowNix.parse_steps(["run test", "deploy production"]) == Err({
	byte_offset: None,
	message: "workflow step 2 is invalid: 'deploy production'; expected 'run <name>' or 'build <name>'",
})

expect match Body.parse(WorkflowCommand.body, "steps: []") {
	Err(_) => Bool.False
	Ok(config) =>
		WorkflowNix.renderer({
			args: ["ci"],
			config,
			config_block: NoConfigBlock,
			host_arch: X64,
			host_os: LINUX,
			related_config: NoRelatedConfig,
		}) == Err({ byte_offset: None, message: "workflow must contain at least one step" })
	}
