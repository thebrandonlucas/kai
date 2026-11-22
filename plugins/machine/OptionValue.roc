## A NixOS option's value for Options and Service, written with bare tags
## and no imports: std's Val tags, plus `SecretPath(name)`, the path a
## secret the machine declares decrypts to, and `Package(name)`, a package
## of the locked nixpkgs by its attribute path:
##
## ```roc
## Options([
## 	("services.tailscale.authKeyFile", SecretPath("tailscale-authkey")),
## 	("services.tailscale.package", Package("tailscale")),
## 	("services.tailscale.extraUpFlags", List([Str("--ssh")])),
## ])
## ```
##
## Attribute sets are lists of (name, value) pairs.
OptionValue := [
	Str(Str),
	Int(I64),
	Bool(Bool),
	List(List(OptionValue)),
	Attrs(List((Str, OptionValue))),
	SecretPath(Str),
	Package(Str),
].{
	is_eq : _
}
