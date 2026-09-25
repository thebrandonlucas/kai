# Locate a Kaifile.roc, evaluate it with the pinned Roc compiler, and read the
# validated Kaifile IR it prints.
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr

import ir.Ir
import ir.Project
import nix.NixBackend

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
		if value.starts_with("/") value else "${base}/${value}"

	split_file : Str -> Location
	split_file = |location| {
		parts = location.split_on("/")
		file = parts.last() ?? location
		root = Str.join_with(parts.drop_last(1), "/")
		{ root: if root.is_empty() "/" else root, file }
	}

	# Probe the compiler's identity before it evaluates configuration. A
	# relative ROC executable belongs to the invocation directory.
	compiler! : () => Try(Str, _)
	compiler! = || {
		override = Env.var_str!("ROC") ?? "roc"
		compiler = if override.contains("/") and !override.starts_with("/") {
			cwd = Env.cwd!()?.to_str()?
			"${cwd}/${override}"
		} else {
			override
		}
		output = Cmd.new_str(compiler).args_str(["version"]).exec_output!()
			.map_err(|err| CompilerUnavailable(compiler, Load.why(err)))?
		expected = "Roc compiler version ${Load.pinned_compiler}"
		actual = output.stdout_utf8.trim()
		if actual != expected {
			return Err(CompilerMismatch(compiler, actual))
		}
		Ok(compiler)
	}

	# The compiler this Kai evaluates configuration with.
	pinned_compiler = compiler_version.trim()

	why = |err|
		match err {
			FailedToGetExitCode({ err: NotFound, .. }) => "not found"
			_ => Str.inspect(err)
		}

	# Kaifile evaluation has only been verified on an x86_64 Linux host.
	check_host! : () => Try({}, [UnsupportedHost])
	check_host! = ||
		match Env.platform!() {
			{ arch: X64, os: LINUX } => Ok({})
			_ => Err(UnsupportedHost)
		}

	# Type-check the whole configuration, reporting compiler diagnostics as-is;
	# in JSON mode the compiler's stdout goes to stderr instead.
	check! : Location, Output.Mode => Try({}, _)
	check! = |project, mode| {
		Load.check_host!()?
		command = Cmd.new_str(Load.compiler!()?)
			.args_str(["check", project.file])
			.cwd(Load.path(project.root))
		match mode {
			Human => command.exec_cmd!().map_err(|_| KaifileInvalid(project.file))
			Json => {
				output = command.stderr(Inherit).run!()?
				Stderr.write_bytes!(output.stdout_bytes)?
				if output.status == Exited(0) {
					Ok({})
				} else {
					Err(KaifileInvalid(project.file))
				}
			}
		}
	}

	# Evaluate the configuration and accept only IR this Kai understands.
	ir! : Location => Try(Ir, _)
	ir! = |project| {
		Load.check_host!()?
		output = Cmd.new_str(Load.compiler!()?)
			.args_str([project.file])
			.cwd(Load.path(project.root))
			.exec_output!()
			.map_err(
				|err|
					match err {
						NonZeroExitCode({ stdout_utf8_lossy, stderr_utf8_lossy, .. }) =>
							KaifileFailed(
								project.file,
								stdout_utf8_lossy.concat(stderr_utf8_lossy),
							)
						_ => KaifileInvalid(project.file)
					},
			)?
		Load.accept(output.stdout_utf8)
	}

	accept : Str -> Try(Ir, _)
	accept = |text| {
		ir = Ir.parse(text).map_err(|err| BadIr(err))?
		missing = ir.unsupported_features(NixBackend.backend.features)
		if !missing.is_empty() {
			return Err(NeedsFeatures(missing))
		}
		Project.validate(ir).map_err(|message| InvalidProject(message))
	}

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

# Output that is not IR is rejected before any planning.
expect match Load.accept("not ir") {
	Err(BadIr(_)) => Bool.True
	_ => Bool.False
}
