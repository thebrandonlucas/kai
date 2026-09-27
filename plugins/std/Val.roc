## A backend-specific value for `Custom` and `Raw` settings, written with bare
## tags and no imports:
##
## ```roc
## Attrs([("shellHook", Str("echo hi")), ("env", Attrs([("DEBUG", Str("1"))]))])
## ```
##
## Attribute sets are lists of (name, value) pairs. Lowered to `ir.Value`.
Val := [
	Str(Str),
	Int(I64),
	Bool(Bool),
	List(List(Val)),
	Attrs(List((Str, Val))),
].{
	is_eq : _
}
