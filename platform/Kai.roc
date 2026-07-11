import Host

## Kai shell protocol helpers.
##
## Roc code emits only the backend-neutral `shell` command. The Zig host sends
## the request to a selected backend adapter executable, receives an argv plan,
## and executes that argv directly.
Kai := [].{
    ## Emit the portable `shell` protocol command using the host-selected adapter.
    ## The host uses `KAI_BACKEND_ADAPTER` when set, otherwise `kai-adapter-nix`.
    shell! : { target : Str, command : List(Str) } => Str
    shell! = |spec|
        Host.kai_shell!("", "shell", spec.target, spec.command)

    ## Emit `shell` using an explicit adapter executable path or PATH name.
    shellWithAdapter! : { adapter : Str, target : Str, command : List(Str) } => Str
    shellWithAdapter! = |spec|
        Host.kai_shell!(spec.adapter, "shell", spec.target, spec.command)

    ## Convenience wrapper for the Nix adapter executable.
    nixShell! : { target : Str, command : List(Str) } => Str
    nixShell! = |spec| shellWithAdapter!({ adapter: "kai-adapter-nix", target: spec.target, command: spec.command })

    ## Convenience wrapper for the Guix adapter executable.
    guixShell! : { target : Str, command : List(Str) } => Str
    guixShell! = |spec| shellWithAdapter!({ adapter: "kai-adapter-guix", target: spec.target, command: spec.command })
}
