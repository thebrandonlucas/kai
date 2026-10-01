# What each std command accomplishes, commands to try, and the Kaifile.roc
# settings that make them work. The kai-help devtool check compiles the
# settings and runs the commands, so help cannot drift from what kai accepts.
import pf.Command

Pages := [].{
	environment = "Environment(\"dev\", [Tools([\"git\"])]),"

	default_shell = "Shell(\"default\", [Use(\"dev\")]),"

	test_task = "Task(\"test\", [Use(\"dev\"), Run([\"git\", \"--version\"])]),"

	copy_build = "Build(\"copy\", [Use(\"dev\"), "
		.concat("Run([\"cp\", \"Kaifile.roc\", \"out\"]), Output(\"out\")]),")

	ci_workflow = "Workflow(\"ci\", [RunTask(\"test\", []), "
		.concat("BuildArtifact(\"copy\")]),")

	model : Command.Page
	model = {
		description: "Print the validated configuration as Kaifile model, the data "
			.concat("kai plans shells and tasks from."),
		examples: ["kai model"],
		config: [],
	}

	update : Command.Page
	update = {
		description: "Pin the package sources Kaifile.roc uses in the lock file, "
			.concat("so shells and tasks keep the same tools until the next update."),
		examples: ["kai update"],
		config: [Pages.environment],
	}

	shell : Command.Page
	shell = {
		description: "Enter a named development environment, or run one command "
			.concat("inside it."),
		examples: ["kai update", "kai shell", "kai shell dev -- git --version"],
		config: [
			Pages.environment,
			Pages.default_shell,
			"Shell(\"dev\", [Use(\"dev\")]),",
		],
	}

	run : Command.Page
	run = {
		description: "Run a named task in its environment; arguments after -- are "
			.concat("appended to the task's command."),
		examples: [
			"kai update",
			"kai run test",
			"kai run test -- --build-options",
		],
		config: [Pages.environment, Pages.test_task],
	}

	build : Command.Page
	build = {
		description: "Build a named artifact in the Nix sandbox from a fresh "
			.concat("snapshot of the project, then print its store path."),
		examples: ["kai update", "kai build copy"],
		config: [Pages.environment, Pages.copy_build],
	}

	workflow : Command.Page
	workflow = {
		description: "Run a named workflow's tasks and builds in order, stopping "
			.concat("at the first step that fails with its exit code."),
		examples: ["kai update", "kai workflow ci", "kai --json workflow ci"],
		config: [
			Pages.environment,
			Pages.test_task,
			Pages.copy_build,
			Pages.ci_workflow,
		],
	}
}
