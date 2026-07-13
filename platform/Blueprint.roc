import Stdout

## Generic helper API for writing Kai blueprints in Roc.
##
## This module defines the stable adapter wire protocol and plan encoder only;
## blueprint-specific lowering belongs in blueprint executables, not in the platform.
Blueprint := [].{
    ## Request sent by the generic Kai host to a Roc blueprint executable.
    Request : { target : Str, argv : List(Str) }

    ## Pure lowering from Kai's portable shell request to executable argv.
    ## Empty argv means enter the blueprint-native interactive shell.
    Backend : Request -> List(Str)

    requestProtocol : Str
    requestProtocol = "kai.adapter.argv.v1"

    planProtocol : Str
    planProtocol = "kai.adapter.plan.v1"

    ## Entrypoint helper for blueprint executables.
    ## Expected argv: executable, request protocol, command, target, command argv...
    main! : List(Str), Backend => I32
    main! = |args, blueprint| {
        protocol = argAt(args, 1)
        command = argAt(args, 2)
        target = argAt(args, 3)

        if protocol != requestProtocol {
            crash "unsupported Kai adapter protocol"
        } else if command != "shell" {
            crash "unsupported Kai adapter command"
        } else {
            commandArgv = List.drop_first(args, 4)
            planArgv = blueprint({ target, argv: commandArgv })
            emitPlan!(planArgv)
            0
        }
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
