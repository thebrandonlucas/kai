# Choosing among the Kaifile's candidate plans: the first fitting candidate
# whose programs run. A chosen candidate's failure never falls back to
# another.
import api.Plan
import api.Protocol

Selection := [].{

	## --backend, or Auto.
	Choice : [Auto, Only(Str)]

	## Unchecked means the decision did not depend on that program.
	Probe : [Missing, Unusable(Str), Usable, Unchecked]

	Candidate : Protocol.Candidate

	fits : Candidate -> Bool
	fits = |candidate|
		match candidate.outcome {
			Unfit(_) => Bool.False
			_ => Bool.True
		}

	## The first of a candidate's programs that is not usable, else Usable.
	status : Candidate, (Str -> Probe) -> Probe
	status = |candidate, probe|
		candidate.probes
			.map(|p| probe(p.program))
			.find_first(|p| p != Usable)
			?? Usable

	## The first fitting candidate whose programs are all usable; `probe`
	## answers Unchecked for a program that was not probed.
	choose :
		Choice,
		List(Candidate),
		(Str -> Probe) -> Try(
			Candidate,
			[
				BackendConflict(Str, Str),
				NoEligibleBackend(List(Str)),
				RequiredBackendUnavailable(Str, Probe),
				NoImplementation(Str),
			],
		)
	choose = |choice, options, probe| {
		reason = |candidate|
			match candidate.outcome {
				Unfit(why) => why
				_ => ""
			}
		match (choice, options.keep_if(Selection.fits)) {
			(Only(backend), _) if options.is_empty() => Err(NoImplementation(backend))
			(Auto, _) if options.is_empty() => Err(NoImplementation(""))
			(Only(backend), []) =>
				Err(BackendConflict(backend, options.first().map_ok(reason) ?? ""))
			(_, [single]) =>
				match Selection.status(single, probe) {
					Usable => Ok(single)
					other => Err(RequiredBackendUnavailable(single.backend, other))
				}
			(_, []) =>
				Err(NoEligibleBackend(options.map(|c| "${c.backend}: ${reason(c)}")))
			(_, fitting) =>
				fitting.find_first(|c| Selection.status(c, probe) == Usable).map_err(
					|_| {
						text = |c| Selection.probe_text(Selection.status(c, probe))
						NoEligibleBackend(fitting.map(|c| "${c.backend} ${text(c)}"))
					},
				)
			}
	}

	## One line saying which backend runs the request and why.
	explain : Choice, List(Candidate), (Str -> Probe), Candidate -> Str
	explain = |choice, options, probe, chosen| {
		why = match (choice, options.keep_if(Selection.fits)) {
			(Only(_), _) => "--backend ${chosen.backend}"
			(Auto, [_]) => "only ${chosen.backend} fits"
			(Auto, fitting) => {
				first = fitting.first() ?? chosen
				if first.backend == chosen.backend {
					"preferred when installed"
				} else {
					probed = Selection.status(first, probe)
					"${first.backend} ${Selection.probe_text(probed)}"
				}
			}
		}
		"using ${chosen.backend} (${why})"
	}

	probe_text : Probe -> Str
	probe_text = |probe|
		match probe {
			Missing => "is not installed"
			Unusable(message) => "is unusable: ${message}"
			Usable => "is usable"
			Unchecked => "was not checked"
		}
}

candidate : Str, [Fit, Unfit(Str), Failed(Str)] -> Selection.Candidate
candidate = |backend, outcome| {
	backend,
	plugin: "std",
	probes: [{ program: backend, flag: DoubleDashVersion }],
	outcome: match outcome {
		Fit => Planned(Plan.{ steps: [], next: Done })
		Unfit(why) => Unfit(why)
		Failed(why) => Failed(why)
	},
}

both = { nix: Usable, guix: Usable }

neither = { nix: Missing, guix: Missing }

only_guix = { nix: Missing, guix: Usable }

only_nix = { nix: Usable, guix: Missing }

probed = |observed| |program|
	if program == "nix" observed.nix else observed.guix

outcome = |choice, options, observed|
	match Selection.choose(choice, options, probed(observed)) {
		Ok(chosen) => Ok(chosen.backend)
		Err(BackendConflict(backend, _)) => Err(Conflict(backend))
		Err(NoEligibleBackend(_)) => Err(NoneEligible)
		Err(RequiredBackendUnavailable(backend, _)) => Err(Unavailable(backend))
		Err(NoImplementation(_)) => Err(NoneEligible)
	}

# Candidates arrive in preference order, only --backend's with --backend.
# The first fitting, usable one wins; a single fitting candidate that is
# not installed is an error rather than a switch to the other backend.
expect {
	generic = [candidate("nix", Fit), candidate("guix", Fit)]
	nix_only = [candidate("nix", Fit), candidate("guix", Unfit("uses overlays"))]
	guix_only = [candidate("nix", Unfit("needs Guix")), candidate("guix", Fit)]
	[
		(Auto, generic, both, Ok("nix")),
		(Auto, generic, only_nix, Ok("nix")),
		(Auto, generic, only_guix, Ok("guix")),
		(Auto, generic, { ..only_guix, nix: Unusable("exit 1") }, Ok("guix")),
		(Auto, generic, neither, Err(NoneEligible)),
		(Only("guix"), [candidate("guix", Fit)], both, Ok("guix")),
		(Only("nix"), [candidate("nix", Fit)], only_guix, Err(Unavailable("nix"))),
		(Only("guix"), [candidate("guix", Unfit("x"))], both, Err(Conflict("guix"))),
		(Auto, guix_only, both, Ok("guix")),
		(Auto, guix_only, only_nix, Err(Unavailable("guix"))),
		(Auto, nix_only, only_guix, Err(Unavailable("nix"))),
		(
			Auto,
			[candidate("nix", Unfit("a")), candidate("guix", Unfit("b"))],
			both,
			Err(NoneEligible),
		),
	].all(
		|(choice, options, observed, expected)|
			outcome(choice, options, observed) == expected,
	)
}

# A plan that failed is still chosen when its backend runs, with no switch
# to another backend; it is passed over only when its backend cannot run.
expect {
	options = [candidate("nix", Failed("no lock")), candidate("guix", Fit)]
	chosen = |observed|
		Selection.choose(Auto, options, probed(observed))
			.map_ok(|c| (c.backend, c.outcome == Failed("no lock")))
	chosen(both) == Ok(("nix", Bool.True))
		and chosen(only_guix) == Ok(("guix", Bool.False))
}

# The explanation names the backend and the reason it was chosen.
expect {
	generic = [candidate("nix", Fit), candidate("guix", Fit)]
	guix_only = [candidate("nix", Unfit("needs Guix")), candidate("guix", Fit)]
	[
		(Auto, generic, only_guix, "using guix (nix is not installed)"),
		(Auto, generic, both, "using nix (preferred when installed)"),
		(Only("guix"), [candidate("guix", Fit)], both, "using guix (--backend guix)"),
		(Auto, guix_only, both, "using guix (only guix fits)"),
	].all(
		|(choice, options, observed, text)|
			match Selection.choose(choice, options, probed(observed)) {
				Ok(chosen) =>
					Selection.explain(choice, options, probed(observed), chosen) == text
				Err(_) => Bool.False
			},
	)
}
