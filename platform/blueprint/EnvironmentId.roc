## An opaque, exact environment identity.
##
## Its distinct type prevents environment identities from being confused with
## requirement identities. Values are case-sensitive and are not normalized.
EnvironmentId :: { value : Str }.{

	## Compares environment identities by their exact values.
	is_eq : EnvironmentId, EnvironmentId -> Bool
	is_eq = |left, right| left.value == right.value

	## Wraps an exact string as an environment identity without validating it.
	##
	## Most applications create these indirectly with `Environment.new`, then
	## rely on `Blueprint.validate` to reject empty or duplicate names.
	new : Str -> EnvironmentId
	new = |value| EnvironmentId.{ value }

	## Returns the exact string wrapped by `new`.
	to_str : EnvironmentId -> Str
	to_str = |id| id.value
}
