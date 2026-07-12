app [main!] { kai: platform "../../platform/main.roc" }

import kai.Adapter

## Guix backend: guix shell [-m manifest.scm] [-- <command...>]
##
## For the generic Kai `environment` convention, a directory target means
## `<target>/manifest.scm`.
guixShell : Adapter.Backend
guixShell = |request| {
	targetArgs =
		if request.target == "" {
			[]
		} else if Str.ends_with(request.target, ".scm") {
			["-m", request.target]
		} else {
			["-m", "${request.target}/manifest.scm"]
		}

	prefix = List.concat(["guix", "shell"], targetArgs)

	if List.len(request.argv) == 0 {
		prefix
	} else {
		List.concat(List.concat(prefix, ["--"]), request.argv)
	}
}

main! : List(Str) => I32
main! = |args| Adapter.main!(args, guixShell)
