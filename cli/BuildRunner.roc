# The sandboxed build runner. Every generated build derivation runs Kai's own
# executable as `kai __build-runner SPEC`, where SPEC is the JSON that
# NixBackend.render_build writes. It refuses unless the build is isolated from
# the caller, runs exactly the declared argv on a writable copy of the project
# snapshot, and copies only the declared, contained, symlink-free output to
# $out. It uses the spec's coreutils, never the user's PATH.
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stderr

import ir.Project
import nix.LockJson

import Snapshot

BuildRunner := [].{
	Spec : {
		project : Str,
		argv : List(Str),
		output : Str,
		path : Str,
		coreutils : Str,
		inputs : Str,
		artifacts : Str,
	}

	remedy = "cannot verify build isolation; user Run was not executed. "
		.concat("Enable sandbox = true and sandbox-fallback = false in the Nix ")
		.concat("daemon configuration and use a local Linux sandbox with /proc.")

	refusal = |detail| "${BuildRunner.remedy} ${detail}"

	decode : LockJson -> Try(BuildRunner.Spec, Str)
	decode = |json| {
		text = |name| LockJson.string(LockJson.field(json, name)?)
		var $argv = []
		for item in LockJson.array(LockJson.field(json, "argv")?)? {
			$argv = $argv.append(LockJson.string(item)?)
		}
		Ok({
			project: text("project")?,
			argv: $argv,
			output: text("output")?,
			path: text("path")?,
			coreutils: text("coreutils")?,
			inputs: text("inputs")?,
			artifacts: text("artifacts")?,
		})
	}

	# The caller's namespace identities: exactly well-formed mnt and net.
	isolation : LockJson -> Try(List((Str, Str)), Str)
	isolation = |json| {
		missing = BuildRunner.refusal("Missing caller namespace observations.")
		fields = match LockJson.field(json, "isolation") {
			Ok(Object(items)) if items.len() == 2 => items
			_ => return Err(missing)
		}
		var $observed = []
		for name in ["mnt", "net"] {
			value = match fields.find_first(|f| f.name == name) {
				Ok({ value: String(text), .. }) => text
				_ => return Err(missing)
			}
			if Snapshot.identity(name, value).is_err() {
				return Err(BuildRunner.refusal("Invalid caller ${name} namespace."))
			}
			$observed = $observed.append((name, value))
		}
		Ok($observed)
	}

	# The build must observe its own, different, namespace.
	compare : Str, Str, Str -> Try({}, Str)
	compare = |name, caller, current|
		if Snapshot.identity(name, current).is_err() {
			Err(BuildRunner.refusal("Invalid build ${name} namespace."))
		} else if current == caller {
			Err(BuildRunner.refusal("Build shares caller ${name} namespace."))
		} else {
			Ok({})
		}

	run! : Str => Try({}, [Exit(I32)])
	run! = |spec_path|
		match BuildRunner.build!(spec_path) {
			Ok({}) => Ok({})
			Err(RunFailed(code)) => Err(Exit(code))
			Err(Refused(message)) => BuildRunner.fail!(message)
			Err(err) => BuildRunner.fail!(Str.inspect(err))
		}

	fail! = |message| {
		_ = Stderr.line!("kai build: ${message}")
		Err(Exit(1))
	}

	build! = |spec_path| {
		json = LockJson.decode(Path.unix(spec_path).read_utf8!()?)
			.map_err(|message| Refused(message))?
		observed = BuildRunner.isolation(json).map_err(|message| Refused(message))?
		spec = BuildRunner.decode(json).map_err(|message| Refused(message))?
		tool! = |program, args| BuildRunner.tool!(spec.coreutils, program, args)
		for (name, caller) in observed {
			link = "/proc/self/ns/${name}"
			current = match tool!("readlink", ["--", link]) {
				Ok(output) => output.drop_suffix("\n")
				Err(err) => return Err(
					Refused(
						BuildRunner.refusal(
							"Cannot read build ${name} namespace: ${Str.inspect(err)}",
						),
					),
				)
			}
			BuildRunner.compare(name, caller, current)
				.map_err(|message| Refused(message))?
		}
		BuildRunner.safe_tree!(Path.unix(spec.project))?
		BuildRunner.check_inputs!(spec.inputs, tool!)?
		cwd = Env.cwd!()?.to_str()?
		work = "${cwd}/kai-work"
		home = "${cwd}/kai-home"
		# Like shutil.copy2: modes and times, never following links.
		copy = ["-R", "-P", "--preserve=mode,timestamps", "--"]
		_ = tool!("cp", copy.concat([spec.project, work]))?
		_ = tool!("chmod", ["-R", "u+w", "--", work])?
		Path.unix(home).create_dir!()?
		(program, args) = match spec.argv {
			[first, .. as rest] => (first, rest)
			[] => return Err(Refused("empty build argv"))
		}
		result = Cmd.new_str(program)
			.args_str(args)
			.cwd(Path.unix(work))
			.envs_str([
				("PATH", spec.path),
				("HOME", home),
				("KAI_INPUTS", spec.inputs),
				("KAI_ARTIFACTS", spec.artifacts),
			])
			.stdin(Inherit)
			.stdout(Inherit)
			.stderr(Inherit)
			.run!()
			.map_err(|err| Refused("cannot run ${program}: ${Str.inspect(err)}"))?
		match result.status {
			Exited(0) => {}
			Exited(code) => return Err(RunFailed(code))
			Signaled(signal) => return Err(RunFailed(128 + signal))
		}
		output = BuildRunner.output!(work, spec.output)?
		out = Env.var_str!("out")?
		match Path.unix(out).type!() {
			Err(PathErr(NotFound, _)) => {}
			Ok(_) => return Err(
				Refused("build wrote directly to $out instead of declared Output"),
			)
			Err(err) => return Err(err)
		}
		_ = tool!("cp", copy.concat([output, out]))?
		Ok({})
	}

	# The declared output, checked to be a contained, link-free tree.
	output! = |work, relative| {
		if !Project.valid_output(relative) {
			return Err(Refused("invalid declared relative output"))
		}
		match Path.unix(work).type!() {
			Ok(IsDir) => {}
			_ => return Err(Refused("build replaced the project workspace"))
		}
		parts = relative.split_on("/")
		var $count = parts.len()
		while $count > 0 {
			ancestor = "${work}/${Str.join_with(parts.take_first($count), "/")}"
			match Path.unix(ancestor).type!() {
				Ok(IsSymLink) => return Err(
					Refused("symlink in declared output path: ${ancestor}"),
				)
				_ => {}
			}
			$count = $count - 1
		}
		output = "${work}/${relative}"
		match Path.unix(output).type!() {
			Ok(_) => {}
			Err(PathErr(NotFound, _)) => return Err(
				Refused("declared output is missing: ${relative}"),
			)
			Err(err) => return Err(err)
		}
		resolved = Snapshot.bytes(Path.unix(output).canonicalize!()?)
		root = Snapshot.bytes(Path.unix(work).canonicalize!()?)
		if !Snapshot.within(root, resolved) {
			return Err(Refused("declared output escapes the project: ${relative}"))
		}
		BuildRunner.safe_tree!(Path.unix(output))?
		Ok(output)
	}

	# Reject links and special files anywhere in a tree, its root included.
	# A loop rather than recursion: https://github.com/roc-lang/roc/issues/11621
	safe_tree! = |root| {
		var $pending = [root]
		while !$pending.is_empty() {
			path = $pending.last() ?? root
			$pending = $pending.drop_last(1)
			match path.type!()? {
				IsDir => {
					$pending = $pending.concat(path.list!()?)
				}
				IsFile => {}
				IsSymLink => return Err(
					Refused(
						"symlink is not allowed in build output/source: ${path.display()}",
					),
				)
				IsOther => return Err(
					Refused(
						"special file is not allowed in build output/source: "
							.concat(path.display()),
					),
				)
			}
		}
		Ok({})
	}

	# Allow the generated farm's links, then follow exactly each one's target
	# (not links within it), rejecting symlinks in any locked source tree.
	check_inputs! = |farm, tool!| {
		for entry in Path.unix(farm).list!()? {
			match entry.type!()? {
				IsSymLink => {}
				_ => return Err(
					Refused("expected generated source link: ${entry.display()}"),
				)
			}
			target = tool!("readlink", ["--", entry.to_str()?])?.drop_suffix("\n")
			resolved = if target.starts_with("/") target else "${farm}/${target}"
			BuildRunner.safe_tree!(Path.unix(resolved))?
		}
		Ok({})
	}

	tool! = |coreutils, program, args|
		Cmd.new_str("${coreutils}/${program}")
			.args_str(args)
			.exec_output!()
			.map_ok(|output| output.stdout_utf8)
			.map_err(
				|err|
					match err {
						NonZeroExitCode({ stderr_utf8_lossy, .. }) =>
							Refused("${program} failed: ${stderr_utf8_lossy.trim()}")
						_ => Refused("${program} failed: ${Str.inspect(err)}")
					},
			)
}

# Only an object of exactly two well-formed identities is a caller witness.
expect {
	witness = |text|
		LockJson.decode("{\"isolation\": {${text}}}") ?? LockJson.Null
	missing = Err(BuildRunner.refusal("Missing caller namespace observations."))
	both = "\"mnt\": \"mnt:[1]\", \"net\": \"net:[2]\""
	[
		(both, Ok([("mnt", "mnt:[1]"), ("net", "net:[2]")])),
		("\"mnt\": \"mnt:[1]\"", missing),
		("${both}, \"pid\": \"pid:[3]\"", missing),
		("\"mnt\": \"mnt:[1]\", \"uts\": \"uts:[2]\"", missing),
		("\"mnt\": \"mnt:[1]\", \"net\": 2", missing),
		(
			"\"mnt\": \"net:[1]\", \"net\": \"net:[2]\"",
			Err(BuildRunner.refusal("Invalid caller mnt namespace.")),
		),
	].all(|(text, expected)| BuildRunner.isolation(witness(text)) == expected)
		and BuildRunner.isolation(LockJson.Null) == missing
}

# A build that shares or cannot identify a namespace never runs user argv.
expect [
	("mnt:[2]", Ok({})),
	("mnt:[1]", Err(BuildRunner.refusal("Build shares caller mnt namespace."))),
	("mnt:[]", Err(BuildRunner.refusal("Invalid build mnt namespace."))),
].all(
	|(current, expected)|
		BuildRunner.compare("mnt", "mnt:[1]", current) == expected,
)

# The spec keeps exact argv strings, empty and control characters included.
expect {
	text = "{\"project\": \"/p\", \"argv\": [\"sh\", \"\", \"a\\nb\"], "
		.concat("\"output\": \"o\", \"path\": \"/b\", \"coreutils\": \"/c\", ")
		.concat("\"inputs\": \"/i\", \"artifacts\": \"/a\"}")
	match LockJson.decode(text) {
		Ok(json) => match BuildRunner.decode(json) {
			Ok(spec) => spec.argv == ["sh", "", "a\nb"] and spec.coreutils == "/c"
			Err(_) => Bool.False
		}
		Err(_) => Bool.False
	}
}
