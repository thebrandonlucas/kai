import EnvironmentId
import Requirement

## A named portable development environment and its required tools.
##
## Requirement order is preserved and is meaningful to backends that present
## tools in a user-facing order. Environment construction is deliberately
## separate from workspace validation.
Environment := { id : EnvironmentId, requirements : List(Requirement) }.{

	## Compares an environment's identity and ordered requirements.
	is_eq : Environment, Environment -> Bool
	is_eq = |left, right| left.id == right.id and left.requirements == right.requirements

	## Creates an unvalidated environment from a name and ordered requirements.
	##
	## Empty or duplicate names and duplicate requirements are reported when the
	## containing `Blueprint.Draft` is passed to `Blueprint.validate`.
	new : { name : Str, requirements : List(Requirement) } -> Environment
	new = |fields| Environment.{ id: EnvironmentId.new(fields.name), requirements: fields.requirements }

	## Returns the exact name supplied to `new`.
	##
	## Names are case-sensitive and are not trimmed or otherwise normalized.
	name : Environment -> Str
	name = |environment| EnvironmentId.to_str(environment.id)
}
