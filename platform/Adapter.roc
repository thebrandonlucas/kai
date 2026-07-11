import Stdout

## Request sent by the generic Kai host to a Roc backend adapter.
Request : { target : Str, argv : List(Str) }

## Pure backend lowering from Kai's portable shell request to executable argv.
Backend : Request -> List(Str)

Adapter := [].{
    requestProtocol : Str
    requestProtocol = "kai.adapter.argv.v1"

    planProtocol : Str
    planProtocol = "kai.adapter.plan.v1"

    ## Entrypoint helper for adapter executables.
    ## Expected argv: executable, request protocol, command, target, command argv...
    main! : List(Str), Backend => I32
    main! = |args, backend| {
        protocol = argAt(args, 1)
        command = argAt(args, 2)
        target = argAt(args, 3)

        if protocol != requestProtocol {
            crash "unsupported Kai adapter protocol"
        } else if command != "shell" {
            crash "unsupported Kai adapter command"
        } else {
            commandArgv = List.drop_first(args, 4)

            if List.len(commandArgv) == 0 {
                crash "empty Kai shell command"
            } else {
                planArgv = backend({ target, argv: commandArgv })
                emitPlan!(planArgv)
                0
            }
        }
    }

    ## Nix backend: nix develop --no-write-lock-file <target> --command <command...>
    nixDevelop : Backend
    nixDevelop = |request| {
        prefix =
            if request.target == "" {
                ["nix", "develop", "--no-write-lock-file", "--command"]
            } else {
                ["nix", "develop", "--no-write-lock-file", request.target, "--command"]
            }

        List.concat(prefix, request.argv)
    }

    ## Guix backend: guix shell [-m manifest.scm|target] -- <command...>
    guixShell : Backend
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

    emitPlan! : List(Str) => {}
    emitPlan! = |argv| {
        _ = Stdout.line!(planProtocol)
        _ = Stdout.line!(List.len(argv).to_str())
        for arg in argv {
            emitArg!(arg)
        }
    }

    emitArg! : Str => {}
    emitArg! = |arg| {
        _ = Stdout.line!(List.len(Str.to_utf8(arg)).to_str())
        _ = Stdout.line!(arg)
    }

    argAt : List(Str), U64 => Str
    argAt = |args, index|
        match List.get(args, index) {
            Ok(arg) => arg
            Err(_) => {
                crash "missing Kai adapter argument"
            }
        }
}
