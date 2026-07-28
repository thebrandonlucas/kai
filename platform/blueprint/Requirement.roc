## An exact, portable identity for an external tool requirement.
##
## A requirement describes a role such as `rust-compiler` or `git`; it does not
## contain a Nix package path or any other backend-specific value. Backends bind
## its exact `id` separately. `display_name` is for people and never participates
## in backend lookup.
Requirement :: { id : Str, display_name : Str }.{

	## Compares both the portable identity and its display name.
	is_eq : Requirement, Requirement -> Bool
	is_eq = |left, right| left.id == right.id and left.display_name == right.display_name

	## Creates an unvalidated requirement identity and display name.
	##
	## IDs are case-sensitive and are not normalized. `Blueprint.validate`
	## rejects empty IDs, duplicates within one environment, and reuse of one ID
	## with conflicting display names.
	new : { id : Str, display_name : Str } -> Requirement
	new = |fields| Requirement.{ id: fields.id, display_name: fields.display_name }

	## Returns the exact identity used for equality and backend bindings.
	id : Requirement -> Str
	id = |requirement| requirement.id

	## Returns the human-readable label supplied to `new`.
	##
	## A backend must not infer a package or tool from this value.
	display_name : Requirement -> Str
	display_name = |requirement| requirement.display_name
}
