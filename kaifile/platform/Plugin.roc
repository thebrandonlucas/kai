# One plugin of a Kaifile: what it contributes and any problems its settings
# have, which fail the Kaifile.roc compile.

## Until plugins declare commands, a plugin describes the project with the
## Kaifile IR text kai plans from.
Plugin := {
	name : Str,
	version : Str,
	describe : Str,
	problems : List(Str),
}.{
	new : { name : Str, version : Str, describe : Str } -> Plugin
	new = |{ name, version, describe }|
		Plugin.{ name, version, describe, problems: [] }

	## Settings a plugin could not accept; `Kaifile.validate` reports them.
	invalid : Str, List(Str) -> Plugin
	invalid = |name, problems|
		Plugin.{ name, version: "", describe: "", problems }
}
