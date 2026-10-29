# Locate a Kaifile.roc, evaluate it with the pinned Roc compiler, and ask it
# what a command should do.
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Random
import pf.Stderr
import pf.System

import api.Protocol
import api.Sexpr

import "../.roc-version" as compiler_version : Str
import "../.roc-overlay" as roc_overlay : Str
import "../platform-release" as platform_release : Str

import Output
import Variables
import Workspace

Load := [].{
	# The configuration file and the directory commands resolve paths against.
	Location : { root : Str, file : Str }

	default_file = "Kaifile.roc"

	# A --file path is relative to the invocation directory; its containing
	# directory becomes the project root.
	project! : Try(Str, [NoValue]) => Try(Location, _)
	project! = |requested| {
		cwd = Env.cwd!()?.to_str()?
		location = Load.resolve(cwd, requested ?? Load.default_file)
		if !(Load.path(location).exists!() ?? Bool.False) {
			return Err(NoKaifile(location))
		}
		canonical = Load.path(location).canonicalize!()?.to_str()?
		Ok(Load.split_file(canonical))
	}

	resolve : Str, Str -> Str
	resolve = |base, value|
		if (value.starts_with("/")) value else "${base}/${value}"

	split_file : Str -> Location
	split_file = |location| {
		parts = location.split_on("/")
		file = parts.last() ?? location
		root = Str.join_with(parts.drop_last(1), "/")
		{ root: if (root.is_empty()) "/" else root, file }
	}

	# Choose the Roc compiler that evaluates Kaifile.roc. It must be the version
	# .roc-version pins. If the ROC environment variable is set, kai uses only
	# that compiler. Otherwise it uses the `roc` on PATH if that is the pinned
	# version, or else has Nix download the pinned version (see `fetched!`).
	compiler! : () => Try(Str, _)
	compiler! = || {
		bundle_variables = [
			Variables.kai_platform_bundle,
			Variables.kai_std_bundle,
			Variables.kai_roc_packages,
		]
		for variable in bundle_variables {
			for bundle in (Variables.read!(variable) ?? "").split_on(":") {
				_ = Load.seed!(bundle)
			}
		}
		match Variables.read!(Variables.roc) {
			# A command such as `roc`, an absolute path, or a path relative to
			# the directory kai was started in, such as `./bin/roc`.
			Ok(requested_compiler_override) => {
				relative = requested_compiler_override.contains("/")
					and !requested_compiler_override.starts_with("/")
				compiler = if relative {
					current_working_directory = Env.cwd!()?.to_str()?
					"${current_working_directory}/${requested_compiler_override}"
				} else {
					requested_compiler_override
				}
				Load.pinned!(compiler)?
				Ok(compiler)
			}
			Err(_) =>
				if Load.pinned!("roc").is_ok() {
					Ok("roc")
				} else {
					Load.fetched!()
				}
		}
	}

	# Whether `compiler` runs and is the Roc version .roc-version pins.
	pinned! : Str => Try({}, _)
	pinned! = |compiler| {
		output = Cmd.new(OsStr.from_str(compiler)).arg("version").capture!()
			.map_err(|err| CompilerUnavailable(compiler, Load.why(err)))?
		actual = output.trim()
		if actual != "Roc compiler version ${Load.pinned_compiler}" {
			return Err(CompilerMismatch(compiler, actual))
		}
		Ok({})
	}

	# The pinned compiler, which Nix downloads from roc-overlay at the revision
	# .roc-overlay pins. Kai keeps a link to it in its cache, so Nix downloads
	# it only once and its garbage collection leaves it in place.
	fetched! : () => Try(Str, _)
	fetched! = || {
		link = "${Load.cache!()?}/kai/roc/${Load.pinned_compiler}"
		compiler = "${link}/bin/roc"
		if Load.pinned!(compiler).is_ok() {
			return Ok(compiler)
		}
		Stderr.line!("kai: getting Roc ${Load.pinned_compiler} with Nix")?
		installable = "${roc_overlay.trim()}#${Load.pinned_compiler}"
		built = Cmd.new("nix")
			.args(["build", "--out-link", OsStr.from_str(link)])
			.arg(OsStr.from_str(installable))
			.inherit_stdio()
			.run!()
		match built {
			Ok(output) if output.status == Exited(0) => {}
			Ok(_) => return Err(CompilerUnavailable(installable, "nix build failed"))
			Err(CmdErr(StartFailed(NotFound, _))) => return Err(NixMissing)
			Err(err) => return Err(CompilerUnavailable(installable, Load.why(err)))
		}
		Load.pinned!(compiler)?
		Ok(compiler)
	}

	# XDG_CACHE_HOME, or ~/.cache.
	cache! : () => Try(Str, _)
	cache! = ||
		match Variables.read!(Variables.xdg_cache_home) {
			Ok(value) if !value.is_empty() => Ok(value)
			_ => Ok("${Variables.read!(Variables.home)?}/.cache")
		}

	# A Nix-installed Kai's wrapper sets KAI_PLATFORM_BUNDLE and KAI_STD_BUNDLE
	# to its unpacked platform and std bundles, <hash>/, and KAI_ROC_PACKAGES to
	# the packages the platform imports, separated by colons. Roc checks its
	# package cache before downloading a URL package, so seeding the cache with
	# them lets a Kaifile.roc pinned to them load offline. Best-effort and silent:
	# otherwise Roc downloads them. Publish with a rename like Roc, which also
	# sweeps stale *.tmp staging directories.
	seed! : Str => Try({}, _)
	seed! = |unpacked| {
		bundle = unpacked.drop_suffix("/")
		hash = bundle.split_on("/").last() ?? ""
		if ["", ".", ".."].contains(hash) {
			return Err(InvalidBundle(bundle))
		}
		store = "${Load.cache!()?}/roc/packages"
		if Load.path("${store}/${hash}/main.roc").exists!()? {
			return Ok({})
		}
		Load.path(store).create_all!()?
		staging = "${store}/${hash}.${Random.seed_u64!()?.to_str()}.tmp"
		Load.path(staging).create_dir!()?
		copied = Cmd.new("cp")
			.args(["-R", "--"])
			.args([OsStr.from_str("${bundle}/."), OsStr.from_str(staging)])
			.call!()
		# A bundle in the read-only Nix store copies read-only.
		writable = match copied {
			Ok(_) =>
				Cmd.new("chmod")
					.args(["-R", "u+w", "--", OsStr.from_str(staging)])
					.call!()
			Err(err) => Err(err)
		}
		result = match writable {
			Ok(_) => Load.path(staging).rename!(Load.path("${store}/${hash}"))
			Err(_) => Err(CopyFailed)
		}
		if result.is_err() {
			_ = Load.path(staging).delete_all!()
		}
		result
	}

	# The compiler this Kai evaluates configuration with.
	pinned_compiler = compiler_version.trim()

	why = |err|
		match err {
			CmdErr(StartFailed(NotFound, _)) => "not found"
			_ => Str.inspect(err)
		}

	# The host's Nix system. Kai evaluates Kaifile.roc and runs Nix only on
	# these hosts; Update.target! selects the generated outputs for it.
	system! : () => Try(Str, [UnsupportedHost])
	system! = || {
		host = System.target!()
		match (host.arch(), host.os()) {
			(X64, Linux(_)) => Ok("x86_64-linux")
			(Arm64, Linux(_)) => Ok("aarch64-linux")
			(Arm64, MacOS(_)) => Ok("aarch64-darwin")
			_ => Err(UnsupportedHost)
		}
	}

	# Kaifile.roc's text, for the header checks below. An unreadable file is
	# left for roc to report.
	text! : Location => Str
	text! = |project|
		Path.read_utf8!(Load.path("${project.root}/${project.file}")) ?? ""

	# A Kaifile.roc from before plugins provided `config` on the platform
	# alone; roc would only report a type mismatch. A file with no app header,
	# such as the platform's own Kaifile module, is no Kaifile at all; roc
	# would only say it has no main! function.
	current : Str, Str -> Try({}, [PreviousHeader, NotAnApp(Str)])
	current = |file, text|
		if text.contains("app [config]") {
			Err(PreviousHeader)
		} else if !text.is_empty() and !text.contains("app [") {
			Err(NotAnApp(file))
		} else {
			Ok({})
		}

	# The releases of the bundles Kaifile.roc names from its platform's
	# repository, unless they are all this kai's. Roc reports a mix only as a
	# platform mismatch, or as type errors when the platform is not this kai's.
	releases : Str -> List(Str)
	releases = |text| {
		header = text.split_on("platform \"").get(1) ?? ""
		platform_url = header.split_on("\"").first() ?? ""
		parts = platform_url.split_on("/releases/download/")
		var $found = []
		if parts.len() == 2 {
			download = "\"${parts.first() ?? ""}/releases/download/"
			for url in text.split_on(download).drop_first(1) {
				release = url.split_on("/").first() ?? ""
				if !$found.contains(release) {
					$found = $found.append(release)
				}
			}
		}
		if ($found == [Load.release]) [] else $found
	}

	# The release of this kai's platform and std, such as v0.0.9.
	release = platform_release.trim().split_on("/").drop_last(1).last() ?? ""

	# Type-check the whole configuration, reporting compiler diagnostics as-is;
	# in JSON mode the compiler's stdout goes to stderr instead. roc exits 2
	# when it found only warnings.
	check! : Location, Output.Mode => Try({}, _)
	check! = |project, mode| {
		_ = Load.system!()?
		text = Load.text!(project)
		Load.current(project.file, text)?
		invalid = KaifileInvalid(project.file, Load.releases(text))
		command = Cmd.new(OsStr.from_str(Load.compiler!()?))
			.args(["check", OsStr.from_str(project.file)])
			.cwd(Load.path(project.root))
		valid = |status| status == Exited(0) or status == Exited(2)
		match mode {
			Human =>
				match command.inherit_stdio().run!() {
					Ok(output) if valid(output.status) => Ok({})
					_ => Err(invalid)
				}
			Json => {
				output = command.stderr(Inherit).run!()?
				Stderr.write_bytes!(output.stdout_bytes)?
				if valid(output.status) {
					Ok({})
				} else {
					Err(invalid)
				}
			}
		}
	}

	# Ask the compiled Kaifile one question, with the request on stdin. roc
	# exits 2 after a complete run when any source has warnings, and 1 on
	# errors even though it still runs the app. With a `cache` directory, a
	# program compiled from the same inputs answers instead, in milliseconds
	# rather than the seconds roc takes to compile; if anything there fails,
	# roc answers and reports it as before.
	ask! : Location, Protocol.Request, Try(Str, [NoCache]) => Try(Protocol.Body, _)
	ask! = |project, request, cache| {
		_ = Load.system!()?
		text = Load.text!(project)
		Load.current(project.file, text)?
		header_releases = Load.releases(text)
		compiler = Load.compiler!()?
		question = Sexpr.to_str(request).to_utf8()
		program = match cache {
			Ok(directory) => Load.compiled!(project, compiler, directory)
			Err(NoCache) => Err(NoCache)
		}
		answered = match program {
			Ok(compiled) =>
				Cmd.new(OsStr.from_str(compiled))
					.cwd(Load.path(project.root))
					.stdin(Bytes(question))
					.run!()
			Err(_) => Err(NotCompiled)
		}
		match answered {
			Ok(ran) if ran.status == Exited(0) =>
				return Load.answer(Str.from_utf8_lossy(ran.stdout_bytes))
			_ => {}
		}
		output = Cmd.new(OsStr.from_str(compiler))
			.arg(OsStr.from_str(project.file))
			.cwd(Load.path(project.root))
			.stdin(Bytes(question))
			.run!()
		match output {
			Ok(ran) if ran.status == Exited(0) =>
				Load.answer(Str.from_utf8_lossy(ran.stdout_bytes))
			Ok(ran) => {
				out = Str.from_utf8_lossy(ran.stdout_bytes)
				errors = Str.from_utf8_lossy(ran.stderr_bytes)
				failure = KaifileFailed(
					project.file,
					out.concat(errors),
					header_releases,
				)
				if ran.status == Exited(2) {
					Load.answer(out).map_err(
						|err|
							match err {
								AnswerTooLarge(size) => AnswerTooLarge(size)
								_ => failure
							},
					)
				} else {
					Err(failure)
				}
			}
			Err(_) => Err(KaifileInvalid(project.file, header_releases))
		}
	}

	# The Kaifile compiled to a program in `directory`, compiled again only
	# when its inputs changed. A record beside it names the program and the
	# inputs it was compiled from; publishing the record last keeps a
	# concurrent kai from pairing a program with another's inputs.
	compiled! : Location, Str, Str => Try(Str, _)
	compiled! = |project, compiler, directory| {
		Workspace.safe_path!(directory)?
		inputs = Load.inputs!(project, compiler)?
		record = "${directory}/${project.file}.inputs"
		stored = Path.read_utf8!(Load.path(record)) ?? ""
		match Load.compiled_from(stored, inputs) {
			Ok(name) if Load.path("${directory}/${name}").is_file!() ?? Bool.False =>
				return Ok("${directory}/${name}")
			_ => {}
		}
		Load.path(directory).create_all!()?
		name = "${project.file}-${Random.seed_u64!()?.to_str()}"
		program = "${directory}/${name}"
		built = Cmd.new(OsStr.from_str(compiler))
			.args(["build", "--opt=dev", OsStr.from_str("--output=${program}")])
			.arg(OsStr.from_str(project.file))
			.cwd(Load.path(project.root))
			.run!()?
		if !(built.status == Exited(0) or built.status == Exited(2)) {
			_ = Load.path(program).delete!()
			return Err(CompileFailed)
		}
		Workspace.atomic_write!(record, "program ${name}\n${inputs}")?
		# A program still answering another kai keeps running once deleted.
		for entry in Load.path(directory).list!()? {
			entry_name = Load.split_file(entry.to_str()?).file
			if entry_name.starts_with("${project.file}-") and entry_name != name {
				_ = entry.delete!()
			}
		}
		Ok(program)
	}

	# What the compiled Kaifile depends on, one per line: the compiler, the
	# host, the packages `roc deps` lists (a remote one by the hash of its
	# contents), and every local file roc reads, by size and modification
	# time as make judges them: each local package's modules, the files they
	# import, and a local platform's host libraries.
	inputs! : Location, Str => Try(Str, _)
	inputs! = |project, compiler| {
		tree = Cmd.new(OsStr.from_str(compiler))
			.args(["deps", OsStr.from_str(project.file)])
			.cwd(Load.path(project.root))
			.stderr(Null)
			.capture!()?
		var $files = []
		for dependency in Load.dependencies(tree) {
			directory = Load.split_file(dependency.file).root
			for entry in Load.path(directory).list!()? {
				source = entry.to_str()?
				if source.ends_with(".roc") and !$files.contains(source) {
					imported = Load.imported_files(Path.read_utf8!(entry) ?? "")
						.map(|file| Workspace.normalize(Load.resolve(directory, file)))
					$files = $files.append(source).concat(imported)
				}
			}
			if dependency.is_platform {
				$files = $files.concat(Load.files_under!("${directory}/targets"))
			}
		}
		system = Load.system!()?
		var $lines = ["roc ${Load.pinned_compiler} ${compiler}", "system ${system}"]
			.concat(tree.split_on("\n"))
		# A package several others import is in the tree once for each.
		for file in $files {
			stamp = Load.stamp!(file)
			if !$lines.contains(stamp) {
				$lines = $lines.append(stamp)
			}
		}
		Ok(Str.join_with($lines, "\n"))
	}

	# The local files in `roc deps` output, by absolute path, and whether each
	# is a platform.
	dependencies : Str -> List({ file : Str, is_platform : Bool })
	dependencies = |tree|
		tree.split_on("\n").keep_oks(
			|line|
				match line.split_first(" (/") {
					Ok({ after, .. }) => {
						file = "/${Str.join_with(after.split_on(")").drop_last(1), ")")}"
						Ok({ file, is_platform: line.contains(") [platform]") })
					}
					Err(_) => Err({})
				},
		)

	# The files a module embeds with `import "file" as name : Str`.
	imported_files : Str -> List(Str)
	imported_files = |text|
		text.split_on("\n").keep_oks(
			|line|
				if line.trim().starts_with("import \"") {
					line.split_on("\"").get(1)
				} else {
					Err(OutOfBounds)
				},
		)

	files_under! : Str => List(Str)
	files_under! = |directory| {
		var $found = []
		for entry in Load.path(directory).list!() ?? [] {
			name = entry.to_str() ?? ""
			$found = if entry.is_dir!() ?? Bool.False {
				$found.concat(Load.files_under!(name))
			} else {
				$found.append(name)
			}
		}
		$found
	}

	stamp! : Str => Str
	stamp! = |file| {
		size = Load.path(file).size_in_bytes!()
		modified = Load.path(file).time_modified!()
		match (size, modified) {
			(Ok(bytes), Ok(time)) =>
				"${file} ${bytes.to_str()} ${time.to_nanos_since_epoch().to_str()}"
			_ => "${file} missing"
		}
	}

	# The program a stored record names, if it was compiled from exactly
	# these inputs, in any order.
	compiled_from : Str, Str -> Try(Str, [Stale])
	compiled_from = |stored, inputs| {
		(first, rest) = match stored.split_first("\n") {
			Ok({ before, after }) => (before, after.split_on("\n"))
			Err(_) => return Err(Stale)
		}
		current_lines = inputs.split_on("\n")
		name = first.drop_prefix("program ")
		same = rest.len() == current_lines.len()
			and rest.all(|line| current_lines.contains(line))
			and current_lines.all(|line| rest.contains(line))
		named = first.starts_with("program ")
			and !name.is_empty()
			and !name.contains("/")
		if same and named {
			Ok(name)
		} else {
			Err(Stale)
		}
	}

	# Decoding here, in a module importing api.Sexpr, avoids a roc check
	# segfault on nightly-2026-09-26-d6267b4 (roc-issues-repro BUG-013, not
	# reported upstream yet); the decode errors are flattened for describe.
	# An answer beyond answer_limit bytes is refused before decoding, so a
	# runaway plan (such as a workflow repeating a large build thousands of
	# times) fails with a clear message instead of stalling kai.
	answer :
		Str -> Try(
			Protocol.Body,
			[BadResponse(Str), IncompatibleProtocol(U64, U64), AnswerTooLarge(U64)],
		)
	answer = |text| {
		size = text.count_utf8_bytes()
		if size > Load.answer_limit {
			return Err(AnswerTooLarge(size))
		}
		match Protocol.decode_response(text) {
			Ok(response) => Ok(response.body)
			Err(Incompatible({ major, minor })) =>
				Err(IncompatibleProtocol(major, minor))
			Err(other) => Err(BadResponse(Str.inspect(other)))
		}
	}

	# Four times the 16 MiB std's Nix planner renders for one workflow.
	answer_limit : U64
	answer_limit = 67108864

	path : Str -> Path
	path = |p| Path.from_os_str(OsStr.from_str(p))
}

# A relative --file resolves against the invocation directory.
expect Load.resolve("/work", "../project/Kaifile.roc")
	== "/work/../project/Kaifile.roc"

# An absolute --file is used as given.
expect Load.resolve("/work", "/project/Kaifile.roc") == "/project/Kaifile.roc"

# The project root is the directory containing the configuration file.
expect Load.split_file("/project/app/Kaifile.roc")
	== { root: "/project/app", file: "Kaifile.roc" }

# A configuration at the filesystem root keeps "/" as its root.
expect Load.split_file("/Kaifile.roc") == { root: "/", file: "Kaifile.roc" }

# Output that is not a response is rejected before anything runs.
expect match Load.answer("not a response") {
	Err(BadResponse(_)) => Bool.True
	_ => Bool.False
}

# An oversized answer is refused before it is decoded.
expect {
	var $text = "x"
	while $text.count_utf8_bytes() <= Load.answer_limit {
		$text = $text.concat($text)
	}
	Load.answer($text) == Err(AnswerTooLarge($text.count_utf8_bytes()))
}

# The pre-plugin header and a module that is not an app are recognized
# before roc runs.
expect Load.current("K", "app [config] { pf: platform \"p\" }")
	== Err(PreviousHeader)
	and Load.current("K", "Kaifile := [].{}\n") == Err(NotAnApp("K"))
	and Load.current("K", "") == Ok({})
	and Load.current("K", "app [kaifile] {\n\tpf: platform \"p\",\n}\n") == Ok({})

# `roc deps` names each local package by its absolute path, after the path
# Kaifile.roc gives; a remote package has no local file.
expect
	Load.dependencies(
		\\Kaifile.roc (/p/Kaifile.roc) [app]
		\\├── ../k (1)/platform/main.roc (/k (1)/platform/main.roc) [platform]
		\\│   └── https://example.com/7j6K.tar.zst
		\\└── std/main.roc (/p/std/main.roc)
		\\    └── ../platform/main.roc (/k (1)/platform/main.roc) [platform] [shared]
	)
		== [
			{ file: "/p/Kaifile.roc", is_platform: Bool.False },
			{ file: "/k (1)/platform/main.roc", is_platform: Bool.True },
			{ file: "/p/std/main.roc", is_platform: Bool.False },
			{ file: "/k (1)/platform/main.roc", is_platform: Bool.True },
		]

# A module's embedded files are read along with it.
expect
	Load.imported_files(
		\\import Output
		\\import "../VERSION" as version : Str
		\\	import "data/a b.txt" as data : Str
	)
		== ["../VERSION", "data/a b.txt"]

# The stored program answers only for exactly the inputs it was compiled
# from, listed in any order.
expect {
	inputs = "roc v1\n/p/Kaifile.roc 10 5\n/p/Tasks.roc 3 7"
	reordered = "roc v1\n/p/Tasks.roc 3 7\n/p/Kaifile.roc 10 5"
	stored = "program Kaifile.roc-1\n${inputs}"
	changed = [
		"roc v1\n/p/Kaifile.roc 10 6\n/p/Tasks.roc 3 7",
		"roc v2\n/p/Kaifile.roc 10 5\n/p/Tasks.roc 3 7",
		"roc v1\n/p/Kaifile.roc 10 5",
		"${inputs}\n/p/New.roc 1 1",
	]
	Load.compiled_from(stored, reordered) == Ok("Kaifile.roc-1")
		and changed.all(|other| Load.compiled_from(stored, other) == Err(Stale))
		and Load.compiled_from("", inputs) == Err(Stale)
		and Load.compiled_from("program ../x\n${inputs}", inputs) == Err(Stale)
}
