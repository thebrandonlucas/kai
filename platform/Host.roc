## Internal hosted-effect boundary for the Kai platform.
## Applications should import `Kai` and `Stdout` instead.
Host := [].{
    # adapter, protocol command, target, command argv
    kai_shell! : Str, Str, Str, List(Str) => Str
    stdout_line! : Str => {}
}
