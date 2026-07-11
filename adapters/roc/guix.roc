app [main!] { kai: platform "../../platform/main.roc" }

import kai.Adapter

## Guix backend: guix shell [-m manifest.scm|target] -- <command...>
guixShell : Adapter.Backend
guixShell = |request| {
    prefix =
        if Str.ends_with(request.target, ".scm") {
            ["guix", "shell", "-m", request.target, "--"]
        } else if request.target == "" {
            ["guix", "shell", "--"]
        } else {
            ["guix", "shell", request.target, "--"]
        }

    List.concat(prefix, request.argv)
}

main! : List(Str) => I32
main! = |args| Adapter.main!(args, guixShell)
