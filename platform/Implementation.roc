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
	plan : Context -> Try(Plan, Plan.Failure),
}.{

	## What a plugin asks the plugin owning the lock to lock: a flake input
	## at a reference, with options, where `Follows(input, source)` makes the
	## flake's own input `input` the project's package source `source`; or a
	## package source, kept locked even when nothing else uses it.
	LockRequest : [Input(Str, Str, List([Follows(Str, Str)])), Source(Str)]

	## A lock request and the plugin making it.
	Requested : { plugin : Str, request : LockRequest }

	## What a plan may depend on besides the plugin's own settings. `phase`
	## counts continuations: 0, then 1 with the files `observed` asked for.
	## `lock_requests` are every plugin's, for the lock owner to lock.
	Context : {
		args : Command.Args,
		backend : Str,
		host : { system : Str },
		layout : Layout,
		revision : { describe : Str, commit_date : Str },
		lock : [Absent, Present(Str)],
		phase : U64,
		observed : List({ path : Str, contents : [Missing, Text(Str)] }),
		lock_requests : List(Requested),
	}
}
