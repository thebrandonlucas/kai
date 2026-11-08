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

		## A Stage of a workflow step that `backend` serves, where the plan
		## mixes backends; a Stage is the chosen backend's.
		StageOn({ label : Str, backend : Str }),

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

		## Makes each program ready in kai's store of pinned downloads and links
		## it into `bin`, in the workspace. The Runs after it have `bin` first on
		## PATH, until the next Realise or Stage.
		Realise({ bin : Str, programs : List(Program) }),

		## Downloads each file into the store and writes a line
		## `<key> <sha256> <size>` for it to `result`, a generated file for a
		## continuation to observe.
		Measure({ files : List({ key : Str, urls : List(Str) }), result : Str }),

		## Writes a line `<sha256> <size> <path>` to `result`, a generated file
		## for a continuation to observe, for each of `files`, absolute paths,
		## that is a regular file; another gets no line.
		Hash({ files : List(Str), result : Str }),

		## Makes each Roc package bundle, a tar.zst named by the hash its URL ends
		## in and unpacking to `main.roc` and the rest, ready in kai's store and
		## places it in Roc's package cache as that directory, unless the cache
		## has it whole, so Roc resolves the URL without downloading.
		PlaceRocPackages(List(Program)),

		## Fails, naming every one that is not on PATH, unless the machine has
		## all of `programs`, which `description` (such as `environment dev`)
		## expects.
		ExpectPrograms({ description : Str, programs : List(Str) }),

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

	## A download pinned by digest and length; a later URL is a mirror of the
	## first. `File` is the program itself. `Archive(path)` is a tar.gz or
	## tar.xz, unpacked whole, with the program at `path` inside it.
	Program : {
		name : Str,
		urls : List(Str),
		sha256 : Str,
		size : U64,
		unpack : [File, Archive(Str)],
	}

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

	## The names closest to a mistyped `given`: at most two edits away, and
	## fewer edits than it has letters.
	closest : Str, List(Str) -> List(Str)
	closest = |given, names| {
		scored = names.map(|name| (name, Plan.distance(given, name)))
		best = scored.fold(3, |lowest, (_, edits)| lowest.min(edits))
		limit = given.count_utf8_bytes().min(3)
		scored.keep_if(|(_, edits)| edits == best and edits < limit)
			.map(|(name, _)| name)
	}

	## How many one-byte insertions, deletions or replacements turn `a` into
	## `b` (Levenshtein distance).
	distance : Str, Str -> U64
	distance = |a, b| {
		right = b.to_utf8()
		var $previous = []
		var $count = 0
		for _ in [0].concat(right) {
			$previous = $previous.append($count)
			$count = $count + 1
		}
		var $row_number = 0
		for x in a.to_utf8() {
			$row_number = $row_number + 1
			var $row = [$row_number]
			var $j = 0
			for y in right {
				deleted = ($previous.get($j + 1) ?? 0) + 1
				inserted = ($row.get($j) ?? 0) + 1
				replaced = ($previous.get($j) ?? 0) + (if (x == y) 0 else 1)
				$row = $row.append(deleted.min(inserted).min(replaced))
				$j = $j + 1
			}
			$previous = $row
		}
		$previous.last() ?? 0
	}
}

# Every step kind survives an S-expression round trip.
expect {
	plan = Plan.{
		steps: [
			Note("n"),
			Print("p"),
			Stage("run test"),
			StageOn({ label: "run fmt", backend: "direct" }),
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
			Realise({
				bin: "/w/bin",
				programs: [
					{
						name: "tool",
						urls: ["https://example.com/tool"],
						sha256: "ab",
						size: 2,
						unpack: File,
					},
					{
						name: "zipped",
						urls: ["https://example.com/a", "https://mirror.example/a"],
						sha256: "cd",
						size: 3,
						unpack: Archive("a/zipped"),
					},
				],
			}),
			Measure({
				files: [{ key: "tool", urls: ["https://example.com/tool"] }],
				result: "/g/measured",
			}),
			Hash({ files: ["/p/dist/app.tar.zst"], result: "/g/hashed" }),
			PlaceRocPackages([
				{
					name: "7j6K",
					urls: ["https://example.com/7j6K.tar.zst"],
					sha256: "ef",
					size: 4,
					unpack: Archive("main.roc"),
				},
			]),
			ExpectPrograms({ description: "environment dev", programs: ["git", "zip"] }),
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

# The closest names are at most two edits away, and fewer than the word has.
expect [
	("rn", ["run", "shell", "build"], ["run"]),
	("moo2", ["moo", "say", "moon"], ["moo", "moon"]),
	("frobnicate", ["run", "shell"], []),
	("x", ["a", "b"], []),
	("bild", ["build", "build-all"], ["build"]),
].all(|(given, names, expected)| Plan.closest(given, names) == expected)
	and Plan.distance("kitten", "sitting") == 3
