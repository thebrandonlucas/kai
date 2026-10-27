# Pure semantic fixtures shared by authoritative-lock and executable-plan tests.
import api.Layout
import model.Model

TestData :: [].{
	layout : Layout
	layout = Layout.{
		project_root: "/project",
		workspace: "/work",
		generated_root: "/generated",
		lock_path: "/authority/inputs.lock",
	}

	builder : Model.Environment
	builder = {
		name: "builder",
		parents: [],
		tools: [{ source: "default", name: "python3" }],
		overlays: [],
		env: [],
		pure: Bool.False,
		aliases: [],
		rust_toolchain: None,
	}

	library : Model.Build
	library = {
		name: "library",
		environment: "builder",
		inputs: ["assets"],
		needs: [],
		run: ["python3", "build.py"],
		output: "dist/library",
		files: All,
		description: "",
		env: [],
		revision: Bool.False,
	}

	application : Model.Build
	application = {
		..library,
		name: "app",
		needs: ["library"],
		output: "dist/app",
		files: All,
		description: "",
		env: [],
		revision: Bool.False,
		run: ["python3", "build.py", "", "two words", "line\nbreak", "$HOME"],
	}

	Data : {
		systems : List(Str),
		sources : List(Model.Source),
		inputs : List(Model.Input),
		environments : List(Model.Environment),
		shells : List(Model.Shell),
		tasks : List(Model.Task),
		build_sources : List(Model.BuildSource),
		builds : List(Model.Build),
		workflows : List(Model.Workflow),
		requires_ : List(Str),
		raw : List(Model.Raw),
		extensions : List(Model.Extension),
	}

	data : Data
	data = {
		systems: ["x86_64-linux"],
		sources: [],
		inputs: [],
		environments: [builder],
		shells: [{ name: "default", environment: "builder", description: "" }],
		tasks: [
			{
				name: "check",
				environment: "builder",
				run: ["python3", "check.py", "configured argument"],
				env: [],
				secrets: [],
				optional_environment_variables: [],
				needs: [],
				description: "",
			},
		],
		build_sources: [{ name: "assets", ref: "path:./assets" }],
		builds: [application, library],
		workflows: [],
		requires_: ["sources", "builds"],
		raw: [],
		extensions: [],
	}

	# Repeated nested runs and diamond builds retain explicit operation identity.
	workflow_data : Data
	workflow_data = {
		..data,
		requires_: ["sources", "builds", "workflows"],
		builds: [
			{ ..application, name: "bundle", needs: ["app", "other"] },
			application,
			{ ..application, name: "other" },
			library,
		],
		workflows: [
			{
				name: "ci",
				description: "",
				steps: [
					BuildArtifact("library"),
					RunTask("check", ["", "two words", "--literal", "a\nb", "$HOME"]),
					RunWorkflow("verify"),
					RunWorkflow("verify"),
					BuildArtifact("bundle"),
				],
			},
			{
				name: "verify",
				description: "",
				steps: [RunTask("check", []), BuildArtifact("bundle")],
			},
			{ name: "empty", description: "", steps: [] },
			{ name: "nothing", description: "", steps: [RunWorkflow("empty")] },
			{ name: "one", description: "", steps: [RunTask("check", [])] },
		],
	}

	project : Data -> Model
	project = |t| Model.{
		format: Model.current_format,
		name: "plan fixture",
		systems: t.systems,
		sources: t.sources,
		inputs: t.inputs,
		environments: t.environments,
		shells: t.shells,
		tasks: t.tasks,
		build_sources: t.build_sources,
		builds: t.builds,
		workflows: t.workflows,
		requires_: t.requires_,
		raw: t.raw,
		extensions: t.extensions,
	}
}
