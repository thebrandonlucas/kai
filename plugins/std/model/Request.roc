# Consumer-selected operations, independent of backend discovery or effects.
Request := [
	Shell(Str, List(Str)),
	Run(Str, List(Str)),
	Build(Str, BuildOutput),
	Workflow(Str),
].{
	is_eq : _

	## Whether a build shows its log as it runs, the absolute path of a link
	## to its artifact that keeps it from garbage collection, and whether it
	## builds, prints its plan instead (`--plan`) or builds again and fails
	## when the output differs (`--rebuild`).
	BuildOutput : {
		print_build_logs : Bool,
		out_link : Try(Str, [NoValue]),
		mode : [Build, Plan, Rebuild],
	}

	## As a workflow step runs a build: log hidden, no link.
	default_output : BuildOutput
	default_output = {
		print_build_logs: Bool.False,
		out_link: Err(NoValue),
		mode: Build,
	}

	build : Str -> Request
	build = |name| Request.Build(name, Request.default_output)
}
