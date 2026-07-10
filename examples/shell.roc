app [main!] { kai: platform "../platform/main.roc" }

import kai.Kai
import kai.Stdout

main! : List(Str) => I32
main! = |_args| {
    spec = { target: "." }

    nix = Kai.nixShell!(spec)
    guix = Kai.guixShell!(spec)

    if nix == "nix develop ." and guix == "guix shell ." {
        Stdout.line!(nix)
        Stdout.line!(guix)
        0
    } else {
        Stdout.line!("unexpected nix: ${nix}")
        Stdout.line!("unexpected guix: ${guix}")
        1
    }
}
