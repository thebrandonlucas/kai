import Host

## Minimal stdout helper for examples and tests.
Stdout := [].{
    line! : Str => {}
    line! = |message| Host.stdout_line!(message)
}
