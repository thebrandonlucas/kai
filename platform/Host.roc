## Internal hosted-effect boundary. Kaifile apps never call these directly.
Host := [].{
	stdin_read_to_end! : () => Try(Str, [StdinErr(Str)])
	stderr_line! : Str => Try({}, [StderrErr(Str)])
	stdout_line! : Str => Try({}, [StdoutErr(Str)])
}
