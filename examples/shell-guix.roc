app [main!] { kai: platform "../platform/main.roc" }

import kai.Kai
import kai.Stdout

main! : List(Str) => I32
main! = |_args| {
    output = Kai.shellWithAdapter!({
        adapter: "./zig-out/bin/kai-adapter-guix",
        target: "./fixtures/shell/manifest.scm",
        command: ["sh", "-c", "zig version >/dev/null && printf kai-guix-ok"],
    })

    if output == "kai-guix-ok" {
        Stdout.line!(output)
        0
    } else {
        Stdout.line!("unexpected guix output: ${output}")
        1
    }
}
