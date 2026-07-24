## Internal effects implemented by the native (zig) host
## The Kai platform will only print to stdout or stderr,
## since doesn't consume stdin but just reads kai.roc.
Host := [].{
	stderr_line! : Str => Try({}, [StderrErr(Str)])
	stdout_line! : Str => Try({}, [StdoutErr(Str)])
}
