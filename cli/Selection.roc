# Pure backend selection: which backend serves one request, decided from the
# configuration's source constraints, --backend and observed executables,
# before any effect. A chosen backend's failure never falls back to another.
import ir.Ir
import ir.Project
import ir.Request
import guix.GuixBackend
import blu.BluBackend

Selection := [].{
	BackendId : [Nix, Guix, Blu]

	BackendChoice : [Auto, Only(BackendId)]

	## Unchecked means the decision did not depend on that executable.
	Probe : [Missing, Unusable(Str), Usable, Unchecked]

	Observed : { nix : Probe, guix : Probe, blu : Probe }

	## Whether a backend can serve the requested closure; unrelated shells,
	## tasks and builds never matter. Nix planning checks builds itself.
	fit : Request, Ir, BackendId -> Try({}, Str)
	fit = |request, ir, backend|
		match backend {
			Guix => GuixBackend.plan(ir, request).map_ok(|_| {})
			Blu => BluBackend.plan(ir, request, "").map_ok(|_| {})
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

	## Candidates that fit, in preference order: Nix before Guix. Blu is only
	## chosen by --backend.
	fitting : BackendChoice, Request, Ir -> List(BackendId)
	fitting = |choice, request, ir| {
		candidates = match choice {
			Auto => [Nix, Guix]
			Only(backend) => [backend]
		}
		candidates.keep_if(|b| Selection.fit(request, ir, b).is_ok())
	}

	resolve :
		BackendChoice,
		Request,
		Ir,
		Observed ->
			Try(
				BackendId,
				[
					BackendConflict(BackendId, Str),
					NoEligibleBackend(List(Str)),
					RequiredBackendUnavailable(BackendId, Probe),
				],
			)
	resolve = |choice, request, ir, observed| {
		probe = |backend|
			match backend {
				Nix => observed.nix
				Guix => observed.guix
				Blu => observed.blu
			}
		usable = |backend|
			match probe(backend) {
				Usable => Bool.True
				_ => Bool.False
			}
		match (choice, Selection.fitting(choice, request, ir)) {
			(Only(backend), []) => {
				why = match Selection.fit(request, ir, backend) {
					Err(message) => message
					Ok({}) => ""
				}
				Err(BackendConflict(backend, why))
			}
			(_, [backend]) =>
				if usable(backend) {
					Ok(backend)
				} else {
					Err(RequiredBackendUnavailable(backend, probe(backend)))
				}
			(_, []) =>
				Err(
					NoEligibleBackend(
						[Nix, Guix].map(
							|b|
								match Selection.fit(request, ir, b) {
									Err(message) => "${Selection.name(b)}: ${message}"
									Ok({}) => ""
								},
						),
					),
				)
			(_, fits) =>
				fits.find_first(usable).map_err(
					|_|
						NoEligibleBackend(
							fits.map(
								|b| "${Selection.name(b)} ${Selection.probe_text(probe(b))}",
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
	explain :
		BackendChoice, Request, Ir, Observed, BackendId -> Str
	explain = |choice, request, ir, observed, backend| {
		why = match choice {
			Only(_) => "--backend ${Selection.name(backend)}"
			Auto =>
				if Selection.fitting(Auto, request, ir).len() == 1 {
					"only ${Selection.name(backend)} fits"
				} else if backend == Nix {
					"preferred when installed"
				} else {
					"nix ${Selection.probe_text(observed.nix)}"
				}
			}
		"using ${Selection.name(backend)} (${why})"
	}

	name : BackendId -> Str
	name = |backend|
		match backend {
			Nix => "nix"
			Guix => "guix"
			Blu => "blu"
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

both = { nix: Usable, guix: Usable, blu: Unchecked }

neither = { nix: Missing, guix: Missing, blu: Unchecked }

only_guix = { nix: Missing, guix: Usable, blu: Unchecked }

only_nix = { nix: Usable, guix: Missing, blu: Unchecked }

shell = |name| Request.Shell(name, [])

outcome = |choice, request, observed|
	match Selection.resolve(choice, request, fixture, observed) {
		Ok(backend) => Ok(backend)
		Err(BackendConflict(backend, _)) => Err(Conflict(backend))
		Err(NoEligibleBackend(_)) => Err(NoneEligible)
		Err(RequiredBackendUnavailable(backend, _)) => Err(Unavailable(backend))
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
expect Selection.fitting(Auto, shell("guixonly"), fixture) == [Guix]
	and Selection.fitting(Auto, shell("generic"), fixture) == [Nix, Guix]

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
	(Auto, shell("generic"), only_guix, Guix, "using guix (nix is not installed)"),
	(Auto, shell("generic"), both, Nix, "using nix (preferred when installed)"),
	(Only(Guix), shell("generic"), both, Guix, "using guix (--backend guix)"),
	(Auto, shell("guixonly"), both, Guix, "using guix (only guix fits)"),
].all(
	|(choice, request, observed, backend, text)|
		Selection.explain(choice, request, fixture, observed, backend) == text,
)
