# Consumer-selected operations, independent of backend discovery or effects.
Request := [
	Shell(Str, List(Str)),
	Run(Str, List(Str)),
	Build(Str),
	Workflow(Str),
].{
	is_eq : _
}
