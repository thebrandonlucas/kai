# What a command asks kai to do: steps kai validates as a whole, then runs.
import Sexpr

## Steps run in order and the first failure stops the plan. `next` asks kai
## to read back files and run the Kaifile again (`Resume`).
Plan := { steps : List(Step), next : Next }.{
	is_eq : _

	encoder_for : _

	parser_for : _

	## The executor vocabulary; kai checks every step before the first runs.
	Step := [
		Note(Str),
		Print(Str),
		Stage(Str),
		Confirm(Str),
		Write(List(File)),
		VerifyPath({ path : Str, argv : List(Str), stdout : Str }),

		## A local source a backend will read: no symlinks or special files.
		CheckSource(Str),
		Snapshot({ root : Str, destination : Str, exclude : List(Str) }),
		InstallRunner({ destination : Str }),

		## kai sets the `secrets` variables from `.env` or its own environment
		## and removes `removed_environment_variables` from the child
		## process's environment: names only, never values.
		Run(
			{
				description : Str,
				argv : List(Str),
				output : Output,
				secrets : List(Str),
				removed_environment_variables : List(Str),
			},
		),
		PublishLock({ previous : [Absent, Present(Str)], contents : Str }),
	].{
		is_eq : _

		encoder_for : _

		parser_for : _
	}

	Next := [Done, Observe(List(Str))].{
		is_eq : _

		encoder_for : _

		parser_for : _
	}

	File : { path : Str, contents : Str }

	## `Quiet` shows the child's stderr only when it fails.
	Output : [Inherit, Quiet, Artifact(Artifact)]

	## `output` is the declared output name; the store path is the child's
	## last stdout line (`nix build --print-out-paths`, `guix build`).
	Artifact : { name : Str, label : Str, output : Str }
}

# Every step kind survives an S-expression round trip.
expect {
	plan = Plan.{
		steps: [
			Note("n"),
			Print("p"),
			Stage("run test"),
			Confirm("go?"),
			Write([{ path: "/g/flake.nix", contents: "{ }\n" }]),
			VerifyPath({ path: "/p/src", argv: ["nix", "hash"], stdout: "sha256-x" }),
			Snapshot({ root: "/p", destination: "/w/src", exclude: [".git"] }),
			InstallRunner({ destination: "/w/runner" }),
			Run({
				description: "shell dev",
				argv: ["bash"],
				output: Inherit,
				secrets: [],
				removed_environment_variables: [],
			}),
			Run({
				description: "lock",
				argv: ["nix", "flake", "update"],
				output: Quiet,
				secrets: [],
				removed_environment_variables: [],
			}),
			Run({
				description: "task t",
				argv: ["bash"],
				output: Inherit,
				secrets: ["TOKEN"],
				removed_environment_variables: ["OTHER"],
			}),
			Run({
				description: "build site",
				argv: ["nix", "build"],
				output: Artifact({ name: "site", label: "site", output: "out" }),
				secrets: [],
				removed_environment_variables: [],
			}),
			PublishLock({ previous: Absent, contents: "{}" }),
			PublishLock({ previous: Present("{}"), contents: "{ }" }),
		],
		next: Observe(["/g/flake.lock"]),
	}
	Sexpr.parse(Sexpr.to_str(plan)) == Ok(plan)
}
