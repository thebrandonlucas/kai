# Backend selection for one request: each backend that may serve it becomes
# a candidate, unfit with a reason, planned or failed, before any effect;
# then the first fitting candidate whose programs run is chosen. A chosen
# candidate's failure never falls back to another.
import api.Plan
import api.Protocol
import ir.Ir
import ir.Project
import ir.Request
import guix.GuixBackend

Selection := [].{
	BackendId : [Nix, Guix]

	BackendChoice : [Auto, Only(BackendId)]

	## Unchecked means the decision did not depend on that program.
	Probe : [Missing, Unusable(Str), Usable, Unchecked]

	Candidate : Protocol.Candidate

	## Plans the request for one backend, or says why it cannot.
	Planner : BackendId -> Try(Plan, Str)

	## Whether a backend can serve the requested closure; unrelated shells,
	## tasks and builds never matter. Nix planning checks builds itself.
	fit : Request, Ir, BackendId -> Try({}, Str)
	fit = |request, ir, backend|
		match backend {
			Guix => GuixBackend.plan(ir, request).map_ok(|_| {})
			Nix => {
				environment = match request {
					Request.Shell(name, _) =>
						ir.shells.find_first(|s| s.name == name)
							.map_ok(|s| s.environment)
							.map_err(|_| "unknown shell: ${name}")?
					Request.Run(name, _) =>
						ir.tasks.find_first(|t| t.name == name)
							.map_ok(|t| t.environment)
							.map_err(|_| "unknown task: ${name}")?
					_ => return Ok({})
				}
				Project.check_environment(ir, Nix, environment)
			}
		}

	## One candidate per backend in preference order, Nix before Guix, or
	## only the --backend one. Only a fitting backend is planned.
	candidates : BackendChoice, Request, Ir, Planner -> List(Candidate)
	candidates = |choice, request, ir, plan| {
		backends = match choice {
			Auto => [Nix, Guix]
			Only(backend) => [backend]
		}
		backends.map(
			|backend| {
				program = Selection.name(backend)
				outcome = match Selection.fit(request, ir, backend) {
					Err(why) => Unfit(why)
					Ok({}) =>
						match plan(backend) {
							Ok(planned) => Planned(planned)
							Err(message) => Failed(message)
						}
					}
				{
					backend: program,
					plugin: "std",
					probes: [{ program, flag: DoubleDashVersion }],
					outcome,
				}
			},
		)
	}

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
		BackendChoice,
		List(Candidate),
		(Str -> Probe) ->
			Try(
				Candidate,
				[
					BackendConflict(Str, Str),
					NoEligibleBackend(List(Str)),
					RequiredBackendUnavailable(Str, Probe),
				],
			)
	choose = |choice, options, probe| {
		reason = |candidate|
			match candidate.outcome {
				Unfit(why) => why
				_ => ""
			}
		match (choice, options.keep_if(Selection.fits)) {
			(Only(backend), []) =>
				Err(
					BackendConflict(
						Selection.name(backend),
						options.first().map_ok(reason) ?? "",
					),
				)
			(_, [single]) =>
				match Selection.status(single, probe) {
					Usable => Ok(single)
					other => Err(RequiredBackendUnavailable(single.backend, other))
				}
			(_, []) =>
				Err(
					NoEligibleBackend(
						options.map(|c| "${c.backend}: ${reason(c)}"),
					),
				)
			(_, fitting) =>
				fitting.find_first(|c| Selection.status(c, probe) == Usable).map_err(
					|_|
						NoEligibleBackend(
							fitting.map(
								|c|
									"${c.backend} ${Selection.probe_text(Selection.status(c, probe))}",
							),
						),
				)
			}
	}

	## `kai update` pins Nix inputs only; Guix channels are not locked.
	lockable : BackendChoice, Ir -> Try({}, [GuixLockUnsupported])
	lockable = |choice, ir| {
		used = ir.environments.fold(
			[],
			|acc, e| acc.concat(e.tools.map(|t| t.source)),
		)
		guix_only = !used.is_empty()
			and used.all(
				|name|
					ir.sources.any(
						|s|
							s.name == name
								and match s.provider {
									GuixPackages(_) => Bool.True
									_ => Bool.False
								},
					),
			)
		if choice == Only(Guix) or guix_only {
			Err(GuixLockUnsupported)
		} else {
			Ok({})
		}
	}

	## One line saying which backend runs the request and why.
	explain : BackendChoice, List(Candidate), (Str -> Probe), Candidate -> Str
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

	name : BackendId -> Str
	name = |backend| if backend == Nix "nix" else "guix"

	probe_text : Probe -> Str
	probe_text = |probe|
		match probe {
			Missing => "is not installed"
			Unusable(message) => "is unusable: ${message}"
			Usable => "is usable"
			Unchecked => "was not checked"
		}
}

environment : Str, Str, List(Str) -> Ir.Environment
environment = |name, source, overlays|
	{ name, parents: [], tools: [{ source, name: "git" }], overlays }

fixture : Ir
fixture = {
	..Ir.empty("selection"),
	systems: ["x86_64-linux"],
	sources: [
		{ name: "default", provider: Auto },
		{ name: "nix", provider: NixPackages("github:NixOS/nixpkgs") },
		{ name: "guix", provider: GuixPackages("channels") },
	],
	inputs: [{ name: "patch", url: "github:example/patch", kind: Overlay }],
	environments: [
		environment("generic", "default", []),
		environment("patched", "default", ["patch"]),
		environment("nixonly", "nix", []),
		environment("guixonly", "guix", []),
	],
	shells: [
		{ name: "generic", environment: "generic" },
		{ name: "patched", environment: "patched" },
		{ name: "nixonly", environment: "nixonly" },
		{ name: "guixonly", environment: "guixonly" },
	],
	tasks: [{ name: "test", environment: "generic", run: ["git"] }],
	requires_: ["builds"],
	builds: [
		{
			name: "app",
			environment: "nixonly",
			inputs: [],
			needs: [],
			run: ["true"],
			output: "out",
		},
	],
}

both = { nix: Usable, guix: Usable }

neither = { nix: Missing, guix: Missing }

only_guix = { nix: Missing, guix: Usable }

only_nix = { nix: Usable, guix: Missing }

shell = |name| Request.Shell(name, [])

planned : Selection.BackendId -> Try(Plan, Str)
planned = |_| Ok(Plan.{ steps: [], next: Done })

probed = |observed| |program|
	if program == "nix" observed.nix else observed.guix

outcome = |choice, request, observed| {
	options = Selection.candidates(choice, request, fixture, planned)
	id = |backend| if backend == "nix" Nix else Guix
	match Selection.choose(choice, options, probed(observed)) {
		Ok(chosen) => Ok(id(chosen.backend))
		Err(BackendConflict(backend, _)) => Err(Conflict(id(backend)))
		Err(NoEligibleBackend(_)) => Err(NoneEligible)
		Err(RequiredBackendUnavailable(backend, _)) => Err(Unavailable(id(backend)))
	}
}

# Source constraints and capabilities narrow the candidates, --backend
# narrows Auto, Nix is preferred when both fit, and a required backend that
# is not installed is an error rather than a switch to the other one.
expect [
	(Auto, shell("generic"), both, Ok(Nix)),
	(Auto, shell("generic"), only_nix, Ok(Nix)),
	(Auto, shell("generic"), only_guix, Ok(Guix)),
	(Auto, shell("generic"), { ..only_guix, nix: Unusable("exit 1") }, Ok(Guix)),
	(Auto, shell("generic"), neither, Err(NoneEligible)),
	(Only(Guix), shell("generic"), both, Ok(Guix)),
	(Only(Nix), shell("generic"), only_guix, Err(Unavailable(Nix))),
	(Only(Guix), shell("nixonly"), both, Err(Conflict(Guix))),
	(Only(Nix), shell("guixonly"), both, Err(Conflict(Nix))),
	(Auto, shell("guixonly"), both, Ok(Guix)),
	(Auto, shell("guixonly"), only_nix, Err(Unavailable(Guix))),
	(Auto, shell("nixonly"), only_guix, Err(Unavailable(Nix))),
	(Auto, shell("patched"), only_guix, Err(Unavailable(Nix))),
	(Only(Guix), shell("patched"), both, Err(Conflict(Guix))),
	(Auto, Request.Build("app"), only_guix, Err(Unavailable(Nix))),
	(Auto, Request.Run("test", []), only_guix, Err(Unavailable(Nix))),
	(Only(Guix), Request.Run("test", []), both, Err(Conflict(Guix))),
	(Only(Guix), Request.Workflow("ci"), both, Err(Conflict(Guix))),
	(Auto, shell("missing"), both, Err(NoneEligible)),
].all(
	|(choice, request, observed, expected)|
		outcome(choice, request, observed) == expected,
)

# Only the requested closure is examined: a Nix-only build or shell elsewhere
# in the project does not keep a Guix shell from being selected.
expect {
	fitting = |request|
		Selection.candidates(Auto, request, fixture, planned)
			.keep_if(Selection.fits)
			.map(|c| c.backend)
	fitting(shell("guixonly")) == ["guix"]
		and fitting(shell("generic")) == ["nix", "guix"]
}

# A plan that failed is still chosen when its backend runs, with no switch
# to another backend; it is passed over only when its backend cannot run.
expect {
	failing = |backend| if backend == Nix Err("no lock") else planned(backend)
	options = Selection.candidates(Auto, shell("generic"), fixture, failing)
	chosen = |observed|
		Selection.choose(Auto, options, probed(observed))
			.map_ok(|c| (c.backend, c.outcome == Failed("no lock")))
	chosen(both) == Ok(("nix", Bool.True))
		and chosen(only_guix) == Ok(("guix", Bool.False))
}

# Guix channels have no lock: update refuses Guix-only sources or --backend
# guix, and still locks projects that use Nix or automatic sources.
expect {
	guix_only = { ..fixture, environments: [environment("g", "guix", [])] }
	[
		(Auto, guix_only, Bool.False),
		(Only(Guix), fixture, Bool.False),
		(Auto, fixture, Bool.True),
		(Only(Nix), fixture, Bool.True),
		(Auto, { ..fixture, environments: [] }, Bool.True),
	].all(|(choice, ir, ok)| Selection.lockable(choice, ir).is_ok() == ok)
}

# The explanation names the backend and the reason it was chosen.
expect [
	(Auto, shell("generic"), only_guix, "using guix (nix is not installed)"),
	(Auto, shell("generic"), both, "using nix (preferred when installed)"),
	(Only(Guix), shell("generic"), both, "using guix (--backend guix)"),
	(Auto, shell("guixonly"), both, "using guix (only guix fits)"),
].all(
	|(choice, request, observed, text)| {
		options = Selection.candidates(choice, request, fixture, planned)
		match Selection.choose(choice, options, probed(observed)) {
			Ok(chosen) =>
				Selection.explain(choice, options, probed(observed), chosen)
					== text
			Err(_) => Bool.False
		}
	},
)
