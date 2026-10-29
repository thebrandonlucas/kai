# What a command asks kai to do: steps kai validates as a whole, then runs.
import Sexpr

## Steps run in order and the first failure stops the plan, unless a MayFail
## tolerates it. `next` asks kai to read back files and run the Kaifile again
## (`Resume`).
Plan := { steps : List(Step), next : Next }.{
	is_eq : _

	encoder_for : _

	parser_for : _

	## The executor vocabulary; kai checks every step before the first runs.
	Step := [
		Note(Str),
		Print(Str),
		Stage(Str),

		## The next n Stages may fail as one: when a Run in them fails, kai
		## notes it, skips the rest of them and continues the plan.
		MayFail(U64),
		Confirm(Str),
		Write(List(File)),

		## A locked local tree, and the command that locks it again.
		VerifyPath(
			{ path : Str, argv : List(Str), stdout : Str, update : Str },
		),

		## A local source a backend will read: no symlinks or special files.
		CheckSource(Str),

		## Copies only the relative paths `files` selects, what lies inside
		## them and the directories above them. Symlinks into `store`, such as
		## a build's out-link, are left out rather than refused.
		Snapshot(
			{
				root : Str,
				destination : Str,
				exclude : List(Str),
				files : [All, Only(List(Str))],
				store : Str,
			},
		),
		InstallRunner({ destination : Str }),

		## kai sets the `secrets` variables from `.env` or its own environment
		## and removes `removed_environment_variables`, except those in
		## `kept_environment_variables`, from the child process's environment:
		## names only, never values.
		Run(
			{
				description : Str,
				argv : List(Str),
				output : Output,
				secrets : List(Str),
				removed_environment_variables : List(Str),
				kept_environment_variables : List(Str),
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

	## `Quiet` shows the child's stderr only when it fails. `Remembered(files)`
	## is Quiet, and kai skips the run once it succeeded with the same argv
	## and the same contents of `files`, which lie in the generated root.
	Output : [Inherit, Quiet, Remembered(List(Str)), Artifact(Artifact)]

	## `output` is the declared output name; the store path is the child's
	## last stdout line (`nix build --print-out-paths`, `guix build`).
	Artifact : { name : Str, label : Str, output : Str }

	## Why there is no plan: a stable `code` scripts can match, as
	## docs/plugin.md lists them, what went wrong, the command that fixes it
	## ("" when none) and the names the request may have meant.
	Failure : { code : Str, message : Str, hint : Str, suggestions : List(Str) }

	## A failure with no code of its own: `plan_failed`.
	fail : Str -> Failure
	fail = |message| { code: "plan_failed", message, hint: "", suggestions: [] }
}

# Every step kind survives an S-expression round trip.
expect {
	plan = Plan.{
		steps: [
			Note("n"),
			Print("p"),
			Stage("run test"),
			MayFail(1),
			Confirm("go?"),
			Write([{ path: "/g/flake.nix", contents: "{ }\n" }]),
			VerifyPath({
				path: "/p/src",
				argv: ["nix", "hash"],
				stdout: "sha256-x",
				update: "kai update src",
			}),
			Snapshot({
				root: "/p",
				destination: "/w/src",
				exclude: [".git"],
				files: Only(["src"]),
				store: "/nix/store",
			}),
			InstallRunner({ destination: "/w/runner" }),
			Run({
				description: "shell dev",
				argv: ["bash"],
				output: Inherit,
				secrets: [],
				removed_environment_variables: [],
				kept_environment_variables: [],
			}),
			Run({
				description: "lock",
				argv: ["nix", "flake", "update"],
				output: Quiet,
				secrets: [],
				removed_environment_variables: [],
				kept_environment_variables: [],
			}),
			Run({
				description: "evaluate",
				argv: ["nix", "eval"],
				output: Remembered(["/g/flake.nix", "/g/flake.lock"]),
				secrets: [],
				removed_environment_variables: [],
				kept_environment_variables: [],
			}),
			Run({
				description: "task t",
				argv: ["bash"],
				output: Inherit,
				secrets: ["TOKEN"],
				removed_environment_variables: ["OTHER"],
				kept_environment_variables: ["VERSION"],
			}),
			Run({
				description: "build site",
				argv: ["nix", "build"],
				output: Artifact({ name: "site", label: "site", output: "out" }),
				secrets: [],
				removed_environment_variables: [],
				kept_environment_variables: [],
			}),
			PublishLock({ previous: Absent, contents: "{}" }),
			PublishLock({ previous: Present("{}"), contents: "{ }" }),
		],
		next: Observe(["/g/flake.lock"]),
	}
	Sexpr.parse(Sexpr.to_str(plan)) == Ok(plan)
}
