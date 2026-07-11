app [main!] { kai: platform "../../platform/main.roc" }

import kai.Adapter

## Nix backend: nix develop --no-write-lock-file <target> --command <command...>
nixDevelop : Adapter.Backend
nixDevelop = |request| {
    prefix =
        if request.target == "" {
            ["nix", "develop", "--no-write-lock-file", "--command"]
        } else {
            ["nix", "develop", "--no-write-lock-file", request.target, "--command"]
        }

    List.concat(prefix, request.argv)
}

main! : List(Str) => I32
main! = |args| Adapter.main!(args, nixDevelop)
