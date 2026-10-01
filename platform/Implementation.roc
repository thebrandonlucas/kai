# How one backend serves one command: whether it fits the request, then its
# plan. Both are pure; the platform calls them for every candidate backend.
import Command
import Layout
import Plan

## `Independent` implementations ignore --backend and need no backend.
Implementation := {
	command : Str,
	backend : [On(Str), Independent],
	fit : Command.Args -> Try({}, Str),
	plan : Context -> Try(Plan, Str),
}.{

	## What a plan may depend on besides the plugin's own settings. `phase`
	## counts continuations: 0, then 1 with the files `observed` asked for.
	Context : {
		args : Command.Args,
		backend : Str,
		host : { system : Str },
		layout : Layout,
		lock : [Absent, Present(Str)],
		phase : U64,
		observed : List({ path : Str, contents : [Missing, Text(Str)] }),
	}
}
