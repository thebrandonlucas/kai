app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.19.0/Hj-J_zxz7V9YurCSTFcFdu6cQJie4guzsPMUi5kBYUk.tar.br",
    json: "https://github.com/lukewilliamboswell/roc-json/releases/download/0.13.0/RqendgZw5e1RsQa3kFhgtnMP8efWoqGRsAvubx4-zus.tar.br",
}

import cli.Stdout
import cli.Arg exposing [Arg]
import json.Json

Request : { protocol : Str, command : Str, target : Str, argv : List(Str) }
Plan : { protocol : Str, argv : List(Str) }

main! : List(Arg) => Result({}, _)
main! = |args| {
    request_json =
        match List.get(args, 1) {
            Ok(arg) => Arg.display(arg)
            Err(_err) => { crash "kai-adapter-guix expects one JSON request argument" }
        }

    request : Request
    request = Decode.from_bytes(Str.to_utf8(request_json), Json.utf8)?

    if request.protocol != "kai.adapter.v0" {
        crash "unsupported Kai adapter protocol"
    } else if request.command != "shell" {
        crash "unsupported Kai adapter command"
    } else {
        prefix =
            if Str.ends_with(request.target, ".scm") {
                ["guix", "shell", "-m", request.target, "--"]
            } else if request.target == "" {
                ["guix", "shell", "--"]
            } else {
                ["guix", "shell", request.target, "--"]
            }

        plan : Plan
        plan = { protocol: "kai.adapter.v0", argv: List.concat(prefix, request.argv) }

        output = Str.from_utf8(Encode.to_bytes(plan, Json.utf8))?
        Stdout.line!(output)
    }
}
