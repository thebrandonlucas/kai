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

import Output

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

	# Probe the compiler's identity before it evaluates configuration. A
	# relative ROC executable belongs to the invocation directory.
	compiler! : () => Try(Str, _)
	compiler! = || {
		seeded = ["KAI_PLATFORM_BUNDLE", "KAI_STD_BUNDLE", "KAI_ROC_PACKAGES"]
		for variable in seeded {
			for bundle in (Env.var_str!(variable) ?? "").split_on(":") {
				_ = Load.seed!(bundle)
			}
		}
		override = Env.var_str!("ROC") ?? "roc"
		compiler = if override.contains("/") and !override.starts_with("/") {
			cwd = Env.cwd!()?.to_str()?
			"${cwd}/${override}"
		} else {
			override
		}
		output = Cmd.new(OsStr.from_str(compiler)).arg("version").capture!()
			.map_err(|err| CompilerUnavailable(compiler, Load.why(err)))?
		expected = "Roc compiler version ${Load.pinned_compiler}"
		actual = output.trim()
		if actual != expected {
			return Err(CompilerMismatch(compiler, actual))
		}
		Ok(compiler)
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
		cache = match Env.var_str!("XDG_CACHE_HOME") {
			Ok(value) if !value.is_empty() => value
			_ => "${Env.var_str!("HOME")?}/.cache"
		}
		store = "${cache}/roc/packages"
		if Load.path("${store}/${hash}/main.roc").exists!()? {
			return Ok({})
		}
		Load.path(store).create_all!()?
		staging = "${store}/${hash}.${Random.seed_u64!()?.to_str()}.tmp"
		Load.path(staging).create_dir!()?
		copied = Cmd.new("cp")
			.args(["-R", "--no-preserve=mode", "--"])
			.args([OsStr.from_str("${bundle}/."), OsStr.from_str(staging)])
			.call!()
		result = match copied {
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
			_ => Err(UnsupportedHost)
		}
	}

	# A Kaifile.roc from before plugins provided `config` on the platform
	# alone; roc would only report a type mismatch. An unreadable file is left
	# for roc to report.
	current! : Location => Try({}, [PreviousHeader])
	current! = |project| {
		file = Load.path("${project.root}/${project.file}")
		Load.current(Path.read_utf8!(file) ?? "")
	}

	current : Str -> Try({}, [PreviousHeader])
	current = |text|
		if (text.contains("app [config]")) Err(PreviousHeader) else Ok({})

	# Type-check the whole configuration, reporting compiler diagnostics as-is;
	# in JSON mode the compiler's stdout goes to stderr instead. roc exits 2
	# when it found only warnings.
	check! : Location, Output.Mode => Try({}, _)
	check! = |project, mode| {
		_ = Load.system!()?
		Load.current!(project)?
		command = Cmd.new(OsStr.from_str(Load.compiler!()?))
			.args(["check", OsStr.from_str(project.file)])
			.cwd(Load.path(project.root))
		valid = |status| status == Exited(0) or status == Exited(2)
		match mode {
			Human =>
				match command.inherit_stdio().run!() {
					Ok(output) if valid(output.status) => Ok({})
					_ => Err(KaifileInvalid(project.file))
				}
			Json => {
				output = command.stderr(Inherit).run!()?
				Stderr.write_bytes!(output.stdout_bytes)?
				if valid(output.status) {
					Ok({})
				} else {
					Err(KaifileInvalid(project.file))
				}
			}
		}
	}

	# Ask the compiled Kaifile one question, with the request on stdin. roc
	# exits 2 after a complete run when any source has warnings, and 1 on
	# errors even though it still runs the app.
	ask! : Location, Protocol.Request => Try(Protocol.Body, _)
	ask! = |project, request| {
		_ = Load.system!()?
		Load.current!(project)?
		output = Cmd.new(OsStr.from_str(Load.compiler!()?))
			.arg(OsStr.from_str(project.file))
			.cwd(Load.path(project.root))
			.stdin(Bytes(Sexpr.to_str(request).to_utf8()))
			.run!()
		match output {
			Ok(ran) if ran.status == Exited(0) =>
				Load.answer(Str.from_utf8_lossy(ran.stdout_bytes))
			Ok(ran) => {
				out = Str.from_utf8_lossy(ran.stdout_bytes)
				errors = Str.from_utf8_lossy(ran.stderr_bytes)
				failure = KaifileFailed(project.file, out.concat(errors))
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
			Err(_) => Err(KaifileInvalid(project.file))
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

# The pre-plugin header is recognized before roc runs.
expect Load.current("app [config] { pf: platform \"p\" }")
	== Err(PreviousHeader)
	and Load.current("app [kaifile] {\n\tpf: platform \"p\",\n}\n") == Ok({})
