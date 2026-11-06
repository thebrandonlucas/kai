# std's model, for a plugin that implements std's commands on a backend of its
# own: the model of the project's settings, the request a command's arguments
# name, and the meaning every backend shares, such as an environment's tools
# or a build's closure. A plugin imports it as `std.StdModel exposing [Model,
# Request]`; the model's types are `Model.Environment`, `Model.Task` and so
# on, and a request's tags are written unqualified, as `Shell(name, argv)`.
import pf.Command
import Config
import ConfigToModel
import LockReport
import pf.Implementation
import pf.Plan
import model.Model
import model.Project
import model.Request

StdModel := [].{

	Model : Model

	Request : Request

	## The pins of a lock file's text as `kai lock` prints them, the JSON
	## docs/lock.md describes, or why the lock cannot be read.
	lock_report : Str -> Try(Str, Str)
	lock_report = LockReport.json

	## The settings' model, or why std refuses them.
	from_settings : List(Config.Setting) -> Try(Model, Str)
	from_settings = ConfigToModel.convert

	## The request a command's parsed arguments name: shell, run, build or
	## workflow.
	request : Str, Command.Args -> Try(Request, Str)
	request = |command, args|
		match command {
			"shell" => {
				command_words = Command.trailing(args, "command")
				Ok(Shell(Command.name(args, "shell"), command_words))
			}
			"run" =>
				Ok(Run(Command.name(args, "task"), Command.trailing(args, "args")))
			"build" => {
				mode = match (Command.flag(args, "plan"), Command.flag(args, "rebuild")) {
					(Bool.True, Bool.True) => return Err("--plan and --rebuild do not combine")
					(Bool.True, _) => Plan
					(_, Bool.True) => Rebuild
					_ => Build
				}
				shown = {
					print_build_logs: Command.flag(args, "print-build-logs"),
					out_link: Command.path(args, "out-link"),
					mode,
				}
				Ok(Build(Command.name(args, "build"), shown))
			}
			"workflow" => Ok(Workflow(Command.name(args, "workflow")))
			_ => Err("std has no ${command} request")
		}

	## A shell, task, build or workflow the project does not declare.
	known : Model, Request -> Try({}, Plan.Failure)
	known = |model, wanted| {
		(kind, requested, declared) = match wanted {
			Shell(name, _) => ("shell", name, model.shells.map(|s| s.name))
			Run(name, _) => ("task", name, model.tasks.map(|t| t.name))
			Build(name, _) => ("build", name, model.builds.map(|b| b.name))
			Workflow(name) => ("workflow", name, model.workflows.map(|w| w.name))
		}
		if declared.contains(requested) {
			Ok({})
		} else {
			message = "unknown ${kind}: ${requested}"
			suggestions = Plan.closest(requested, declared)
			Err({ code: "unknown_name", message, hint: "", suggestions })
		}
	}

	## A build declaring Revision receives the project's revision in its
	## environment, over its own Env.
	revised : Model, Implementation.Context -> Model
	revised = |model, ctx| {
		revision = [
			{ name: "KAI_REVISION", value: ctx.revision.describe },
			{ name: "KAI_COMMIT_DATE", value: ctx.revision.commit_date },
		]
		stamp = |build|
			if build.revision {
				{ ..build, env: Project.merge_env(build.env, revision) }
			} else {
				build
			}
		{ ..model, builds: model.builds.map(stamp) }
	}

	## The model with each environment's parents resolved, or why it is
	## invalid.
	validate : Model -> Try(Model, Str)
	validate = Project.validate

	## The model as it is on `system`: each environment with what its
	## OnSystems add there.
	for_system : Model, Str -> Model
	for_system = Project.for_system

	## The tools an environment's packages come from, its aliases',
	## PackageEnv's and those it adds on some systems included.
	environment_tools : Model.Environment -> List(Model.Tool)
	environment_tools = Project.environment_tools

	## Whether only the direct backend serves an environment.
	direct_only : Model, Model.Environment -> Bool
	direct_only = Project.direct_only

	## `base` with `overrides` replacing its variables of the same name.
	merge_env : List(Model.Variable), List(Model.Variable) -> List(Model.Variable)
	merge_env = Project.merge_env

	## The `env` argv prefix that runs a command in the project-relative
	## directory `dir`, unless it is empty, with `variables` set.
	env_command : Str, List(Model.Variable) -> List(Str)
	env_command = Project.env_command

	## The secrets other tasks declare, which a task never receives unless it
	## declares them too.
	other_tasks_secrets : Model, Model.Task -> List(Str)
	other_tasks_secrets = Project.other_tasks_secrets

	## KAI_ARTIFACTS for a task with Needs: its artifacts directory under the
	## workspace.
	artifacts_variable : Model.Task, Str -> List(Model.Variable)
	artifacts_variable = Project.artifacts_variable

	## The named builds and those they need, each once, before its consumers.
	builds_closure : Model, List(Str) -> Try(List(Model.Build), Str)
	builds_closure = Project.builds_closure

	## A workflow's steps, its workflows expanded.
	workflow_steps : Model, Str -> Try(List(Model.AtomicStep), Str)
	workflow_steps = Project.workflow_steps

	## The directory builds copy: the project root, or the ancestor BuildRoot
	## names.
	snapshot_root : Model, Str -> Try(Str, Str)
	snapshot_root = Project.snapshot_root

	## What a closure's shared snapshot holds: the files each build selects.
	snapshot_files : List(Model.Build) -> [All, Only(List(Str))]
	snapshot_files = Project.snapshot_files
}

# A plugin finds what a request names among the project's declarations, or is
# told the closest declared names.
expect {
	settings = [
		Name("x"),
		Environment("dev", [Tools(["hello"])]),
		Task("moo", [Use("dev"), Run(["hello"])]),
	]
	match StdModel.from_settings(settings) {
		Ok(model) => {
			missing = |wanted|
				StdModel.known(model, wanted).map_err(|f| (f.code, f.suggestions))
			missing(Run("moo", [])) == Ok({})
				and missing(Run("mooo", [])) == Err(("unknown_name", ["moo"]))
				and missing(Shell("default", [])) == Err(("unknown_name", []))
		}
		Err(_) => Bool.False
	}
}
