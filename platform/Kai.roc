import Host

## Kai backend selector plus shell protocol helpers.
##
## Roc code emits the backend-neutral `shell` command; the Zig host lowers and executes it.
Kai := [Nix, Guix].{
    ## Emit the portable `shell` protocol command and execute it for a backend.
    shell! : Kai, { target : Str, command : List(Str) } => Str
    shell! = |backend, spec|
        Host.kai_shell!(backendName(backend), "shell", spec.target, spec.command)

    ## Execute `shell` with the Nix backend (`nix develop ... --command`).
    nixShell! : { target : Str, command : List(Str) } => Str
    nixShell! = |spec| shell!(Nix, spec)

    ## Execute `shell` with the Guix backend (`guix shell ... --`).
    guixShell! : { target : Str, command : List(Str) } => Str
    guixShell! = |spec| shell!(Guix, spec)
}

backendName : Kai -> Str
backendName = |backend|
    match backend {
        Nix => "nix"
        Guix => "guix"
    }
