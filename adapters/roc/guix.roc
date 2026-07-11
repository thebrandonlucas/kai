app [main!] { kai: platform "../../platform/main.roc" }

import kai.Adapter

## Guix backend: guix shell [-m manifest.scm] -- <command...>
##
## For the generic Kai `environment` convention, a directory target means
## `<target>/manifest.scm`.
guixShell : Adapter.Backend
guixShell = |request| {
	prefix = 
		if request.target == "" {
			["guix", "shell", "--"]
		} else if Str.ends_with(request.target, ".scm") {
			["guix", "shell", "-m", request.target, "--"]
		} else {
			["guix", "shell", "-m", "${request.target}/manifest.scm", "--"]
		}

	List.concat(prefix, request.argv)
}

main! : List(Str) => I32
main! = |args| Adapter.main!(args, guixShell)
