## A closed set of supported target systems.
##
## The variants represent `aarch64-darwin`, `aarch64-linux`,
## `x86_64-darwin`, and `x86_64-linux`. Applications declare targets explicitly
## on a `Blueprint.Draft`; backends must not infer the current host system.
Target := [Aarch64Darwin, Aarch64Linux, X86_64Darwin, X86_64Linux].{

	## Compares target systems by their closed variants.
	is_eq : Target, Target -> Bool
	is_eq = |left, right| Target.to_str(left) == Target.to_str(right)

	## Returns the stable lowercase architecture-system spelling for a target.
	##
	## This function is total over the closed target set and performs no host
	## detection.
	to_str : Target -> Str
	to_str = |target|
		match target {
			Aarch64Darwin => "aarch64-darwin"
			Aarch64Linux => "aarch64-linux"
			X86_64Darwin => "x86_64-darwin"
			X86_64Linux => "x86_64-linux"
		}
}

## Every supported target maps to its portable canonical spelling.
expect [
	Target.to_str(Target.X86_64Linux),
	Target.to_str(Target.Aarch64Linux),
	Target.to_str(Target.X86_64Darwin),
	Target.to_str(Target.Aarch64Darwin),
] == ["x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin"]
