# What each command accomplishes, commands to try, and the Kaifile.roc
# settings (inside config) that make those commands work. The kai-help
# devtool check compiles the settings and runs the commands, so help cannot
# drift from what kai actually accepts.
Help := [].{
	Page : { summary : Str, examples : List(Str), config : List(Str) }

	environment = "Environment(\"dev\", [Tools([\"git\"])]),"

	default_shell = "Shell(\"default\", [Use(\"dev\")]),"

	test_task = "Task(\"test\", [Use(\"dev\"), Run([\"git\", \"--version\"])]),"

	kai : Help.Page
	kai = {
		summary: "Developer environments, tasks and builds from a Kaifile.roc.",
		examples: ["kai check", "kai update", "kai shell", "kai run test"],
		config: [Help.environment, Help.default_shell, Help.test_task],
	}

	check : Help.Page
	check = {
		summary: "Compile Kaifile.roc and report whether its configuration is "
			.concat("valid, without building or running anything."),
		examples: [
			"kai check",
			"kai --file Kaifile.roc check",
			"kai --json check",
		],
		config: [],
	}

	ir : Help.Page
	ir = {
		summary: "Print the validated configuration as Kaifile IR, the data "
			.concat("kai plans shells and tasks from."),
		examples: ["kai ir"],
		config: [],
	}

	update : Help.Page
	update = {
		summary: "Pin the package sources Kaifile.roc uses in the lock file, so "
			.concat("shells and tasks keep the same tools until the next update."),
		examples: ["kai update"],
		config: [Help.environment],
	}

	shell : Help.Page
	shell = {
		summary: "Enter a named development environment, or run one command "
			.concat("inside it."),
		examples: ["kai update", "kai shell", "kai shell dev -- git --version"],
		config: [
			Help.environment,
			Help.default_shell,
			"Shell(\"dev\", [Use(\"dev\")]),",
		],
	}

	copy_build = "Build(\"copy\", [Use(\"dev\"), "
		.concat("Run([\"cp\", \"Kaifile.roc\", \"out\"]), Output(\"out\")]),")

	run : Help.Page
	run = {
		summary: "Run a named task in its environment; arguments after -- are "
			.concat("appended to the task's command."),
		examples: [
			"kai update",
			"kai run test",
			"kai run test -- --build-options",
		],
		config: [Help.environment, Help.test_task],
	}

	build : Help.Page
	build = {
		summary: "Build a named artifact in the Nix sandbox from a fresh snapshot "
			.concat("of the project, then print its store path."),
		examples: ["kai update", "kai build copy"],
		config: [Help.environment, Help.copy_build],
	}

	ci_workflow = "Workflow(\"ci\", [RunTask(\"test\", []), "
		.concat("BuildArtifact(\"copy\")]),")

	workflow : Help.Page
	workflow = {
		summary: "Run a named workflow's tasks and builds in order, stopping "
			.concat("at the first step that fails with its exit code."),
		examples: ["kai update", "kai workflow ci", "kai --json workflow ci"],
		config: [
			Help.environment,
			Help.test_task,
			Help.copy_build,
			Help.ci_workflow,
		],
	}

	# Weaver drops leading spaces from descriptions, so headings rather than
	# indentation mark the sections. A parent lists only the summary.
	describe : Help.Page -> Str
	describe = |page| {
		section = |heading, lines|
			if lines.is_empty() [] else [Str.join_with([heading].concat(lines), "\n")]
		Str.join_with(
			[page.summary]
				.concat(section("Examples:", page.examples))
				.concat(section("Kaifile.roc (inside config):", page.config)),
			"\n\n",
		)
	}

	summary : Str -> Str
	summary = |description| description.split_on("\n\n").first() ?? description

	# Color is decoration only: NO_COLOR (when non-empty), --no-color or output
	# that is not a terminal all get plain text.
	text_style : { terminal : Bool, no_color : Str, flag : Bool } -> [Color, Plain]
	text_style = |{ terminal, no_color, flag }|
		if terminal and no_color.is_empty() and !flag Color else Plain
}

# Only an interactive terminal without an opt-out gets color.
expect [
	({ terminal: Bool.True, no_color: "", flag: Bool.False }, Color),
	({ terminal: Bool.False, no_color: "", flag: Bool.False }, Plain),
	({ terminal: Bool.True, no_color: "1", flag: Bool.False }, Plain),
	({ terminal: Bool.True, no_color: "", flag: Bool.True }, Plain),
	({ terminal: Bool.False, no_color: "1", flag: Bool.True }, Plain),
].all(|(input, expected)| Help.text_style(input) == expected)

# A parent's command list shows the summary, not the examples.
expect Help.summary(Help.describe(Help.shell)) == Help.shell.summary
	and Help.summary(Help.describe(Help.ir)) == Help.ir.summary
