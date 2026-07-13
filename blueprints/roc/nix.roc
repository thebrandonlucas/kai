app [main!] { kai: platform "../../platform/main.roc" }

import kai.Blueprint

## Nix blueprint: nix develop --no-write-lock-file <target> [--command <command...>]
nixDevelop : Blueprint.Backend
nixDevelop = |request| {
    prefix =
        if request.target == "" {
            ["nix", "develop", "--no-write-lock-file"]
        } else {
            ["nix", "develop", "--no-write-lock-file", request.target]
        }

    if List.len(request.argv) == 0 {
        prefix
    } else {
        List.concat(List.concat(prefix, ["--command"]), request.argv)
    }
}

main! : List(Str) => I32
main! = |args| Blueprint.main!(args, nixDevelop)
