import pf.OsStr
import pf.Stdout

Plugin := [].{
	run! : List(OsStr) => Try({}, _)
	run! = |_args| {
		Stdout.line!("running plugin")
	}
}
