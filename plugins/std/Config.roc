# Typed authoring values convert into the shared semantic project model.
import EnvName
import FlakeRef
import InputName
import System
import TaskName
import Tool
import Val
import WorkflowName

## Pure settings that compose through ordinary Roc lists and functions.
Config :: [].{

	## Named sources describe provider intent, not host discovery. Omitting the
	## "default" source is equivalent to `Packages("default", Auto)`.
	## Overlay inputs apply only where an environment selects them.
	## `Custom` and `Raw` retain consumer-specific extension data.
	Setting : [
		Name(Str),
		Systems(List(System)),
		Packages(InputName, PackageSource),
		Input(InputName, FlakeRef),
		Overlay(InputName, FlakeRef),
		Environment(EnvName, List(EnvironmentSetting)),
		Shell(EnvName, List(ShellSetting)),
		Task(TaskName, List(TaskSetting)),
		Source(InputName, FlakeRef),
		Fetch(InputName, List(FetchFile)),
		Build(InputName, List(BuildSetting)),
		Workflow(WorkflowName, List(WorkflowStep)),
		Custom(Str, Str, Val),
		Raw(Str, Str, Val),
	]

	## Workflows reference declarations; argv contains literal extra arguments.
	## A step in MayFail that fails is noted and the workflow continues: a
	## failing workflow there stops, but not the one running it. Description
	## is no step: it is the workflow's summary in help.
	WorkflowStep : [
		RunTask(TaskName, List(Str)),
		BuildArtifact(InputName),
		RunWorkflow(WorkflowName),
		MayFail(Step),
		Description(Str),
	]
	Step : [
		RunTask(TaskName, List(Str)),
		BuildArtifact(InputName),
		RunWorkflow(WorkflowName),
	]

	## A file pinned by its published sha256 (hex or SRI) for each system it
	## exists for; the host's system picks one. A build lists it in Inputs, and
	## a tool "<name>#<binary>" puts it on PATH as the executable <binary>.
	FetchFile : { system : System, url : Str, sha256 : Str }

	PackageSource : [Auto, From(Provider)]
	Provider : [NixPackages(FlakeRef), GuixPackages(Str)]

	## Each setting but Alias occurs at most once. Extend inherits tools,
	## overlays and aliases parent first; an omitted or empty list does not clear
	## inherited values. Env sets variables in the environment's shells, tasks
	## and builds. They override the parent's by name, and a task's or build's
	## Env overrides them. Pure starts its shells and tasks from a clean
	## environment, as does Extend of a Pure environment. Alias(name, tool,
	## binary) puts a command `name` on PATH that runs the tool's
	## `bin/<binary>`, without the tool's other binaries; it needs Nix.
	## RustToolchain takes a rust-toolchain.toml's text and adds the toolchain
	## its [toolchain] table pins, overriding the parent's; it needs Nix and an
	## Overlay providing rust-bin, such as rust-overlay.
	EnvironmentSetting : [
		Tools(List(Tool)),
		Overlays(List(InputName)),
		Extend(EnvName),
		Env(List((Str, Str))),
		Pure,
		Alias(Str, Tool, Str),
		RustToolchain(Str),
	]

	## A shell is an alias for exactly one environment. A Description, in a
	## shell, task or build, is its summary in help instead of its command.
	ShellSetting : [Use(EnvName), Description(Str)]

	## Tasks require exactly one Use and one nonempty argv Run. Secrets names
	## the variables the task receives from `.env` or kai's environment when
	## it runs; their values never enter the Kaifile, plan or store.
	## OptionalEnvironmentVariables names those it receives from kai's
	## environment only when set there. Needs names builds kai builds first,
	## for the task in `$KAI_ARTIFACTS/<name>`.
	TaskSetting : [
		Use(EnvName),
		Run(List(Str)),
		Env(List((Str, Str))),
		Secrets(List(Str)),
		Needs(List(InputName)),
		OptionalEnvironmentVariables(List(Str)),
		Description(Str),
	]

	## Builds require Use, Run and one relative Output. Optional Inputs select
	## non-flake Sources or Fetches; Needs selects build artifacts, not tasks.
	## Sources and artifacts remain separate read-only inputs, never merged.
	## Files limits the project copy to the given project-relative paths.
	## Revision sets KAI_REVISION, the project's `git describe --tags --always
	## --dirty`, and KAI_COMMIT_DATE, its last commit's date, both empty outside
	## git. It is opt-in, since the build then changes with every commit.
	BuildSetting : [
		Use(EnvName),
		Inputs(List(InputName)),
		Needs(List(InputName)),
		Run(List(Str)),
		Output(Str),
		Files(List(Str)),
		Env(List((Str, Str))),
		Revision,
		Description(Str),
	]
}
