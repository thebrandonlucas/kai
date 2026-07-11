import Host

## Kai shell protocol helpers.
##
## Roc code emits only the backend-neutral `shell` command. The Zig host sends
## the request to a selected backend adapter executable, receives an argv plan,
## and executes that argv directly.
Kai := [].{
    ## Emit the portable `shell` protocol command using the adapter selected by
    ## `KAI_BACKEND_ADAPTER`.
    shell! : { target : Str, command : List(Str) } => Str
    shell! = |spec|
        Host.kai_shell!("", "shell", spec.target, spec.command)

    ## Emit `shell` using an explicit adapter executable path or PATH name.
    shellWithAdapter! : { adapter : Str, target : Str, command : List(Str) } => Str
    shellWithAdapter! = |spec|
        Host.kai_shell!(spec.adapter, "shell", spec.target, spec.command)
}
