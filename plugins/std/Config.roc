# Typed authoring values lower into the shared semantic project model.
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
		Build(InputName, List(BuildSetting)),
		Workflow(WorkflowName, List(WorkflowStep)),
		Custom(Str, Str, Val),
		Raw(Str, Str, Val),
	]

	## Workflows reference declarations; argv contains literal extra arguments.
	WorkflowStep : [
		RunTask(TaskName, List(Str)),
		BuildArtifact(InputName),
		RunWorkflow(WorkflowName),
	]

	PackageSource : [Auto, From(Provider)]
	Provider : [NixPackages(FlakeRef), GuixPackages(Str)]

	## Each setting occurs at most once. Extend inherits tools and overlays
	## parent first; an omitted or empty list does not clear inherited values.
	EnvironmentSetting : [
		Tools(List(Tool)),
		Overlays(List(InputName)),
		Extend(EnvName),
	]

	## A shell is an alias for exactly one environment.
	ShellSetting : [Use(EnvName)]

	## Tasks require exactly one Use and one nonempty argv Run.
	TaskSetting : [Use(EnvName), Run(List(Str))]

	## Builds require Use, Run and one relative Output. Optional Inputs select
	## locked non-flake Sources; Needs selects build artifacts, not task names.
	## Sources and artifacts remain separate read-only inputs, never merged.
	BuildSetting : [
		Use(EnvName),
		Inputs(List(InputName)),
		Needs(List(InputName)),
		Run(List(Str)),
		Output(Str),
	]
}
