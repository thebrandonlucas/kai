app [main!] { kai: platform "../platform/main.roc" }

import kai.Kai
import kai.Stdout

main! : List(Str) => I32
main! = |_args| {
    output = Kai.shellWithAdapter!({
        adapter: "./zig-out/bin/kai-adapter-nix",
        target: "./fixtures/shell",
        command: ["sh", "-c", "zig version >/dev/null && printf kai-nix-ok"],
    })

    if output == "kai-nix-ok" {
        Stdout.line!(output)
        0
    } else {
        Stdout.line!("unexpected nix output: ${output}")
        1
    }
}
