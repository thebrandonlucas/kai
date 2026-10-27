# Consumer-selected operations, independent of backend discovery or effects.
Request := [
	Shell(Str, List(Str)),
	Run(Str, List(Str)),
	Build(Str, BuildOutput),
	Workflow(Str),
].{
	is_eq : _

	## Whether a build shows its log as it runs, and the absolute path of a
	## link to its artifact that keeps it from garbage collection.
	BuildOutput : { print_build_logs : Bool, out_link : Try(Str, [NoValue]) }

	## As a workflow step runs a build: log hidden, no link.
	default_output : BuildOutput
	default_output = { print_build_logs: Bool.False, out_link: Err(NoValue) }

	build : Str -> Request
	build = |name| Request.Build(name, Request.default_output)
}
