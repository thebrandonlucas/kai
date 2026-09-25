# Small inspection interface. Executable operations use NixBackend.plan instead.
import ir.Ir

Backend := {
	name : Str,
	features : List(Str),
	render : Ir -> Try(List(File), Str),
}.{

	## Inspection returns relative names; executable Plan files are absolute.
	File : { path : Str, contents : Str }
}
