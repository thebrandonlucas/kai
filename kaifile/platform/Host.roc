## Internal hosted-effect boundary. Kaifile apps never call these directly.
Host := [].{
	stderr_line! : Str => Try({}, [StderrErr(Str)])
	stdout_line! : Str => Try({}, [StdoutErr(Str)])
}
