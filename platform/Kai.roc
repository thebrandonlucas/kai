import Host

## Kai backend selector plus shell protocol helpers.
##
## Roc code emits the backend-neutral `shell` command; the Zig host lowers it.
Kai := [Nix, Guix].{
    ## Emit the portable `shell` protocol command and lower it for a backend.
    shell! : Kai, { target : Str } => Str
    shell! = |backend, spec|
        Host.kai_shell!(backendName(backend), "shell", spec.target)

    ## Lower `shell` to the Nix backend (`nix develop`).
    nixShell! : { target : Str } => Str
    nixShell! = |spec| shell!(Nix, spec)

    ## Lower `shell` to the Guix backend (`guix shell`).
    guixShell! : { target : Str } => Str
    guixShell! = |spec| shell!(Guix, spec)
}

backendName : Kai -> Str
backendName = |backend|
    match backend {
        Nix => "nix"
        Guix => "guix"
    }
