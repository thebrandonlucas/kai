# Run a built `kai build` against real Nix on a copy of examples/artifacts:
# artifacts have exact bytes, every build snapshots the project afresh, a
# missing output or symlink never reports success, a changed locked source
# needs `kai update`, the sandbox hides host files and TCP, and the lock is
# never written.
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stdout
import pf.Tcp

import KaiUpdate

KaiBuild := [].{
	run! = |binary| {
		(kai, project) = KaiUpdate.fixture!(
			binary,
			"artifacts",
			["assets", "src"],
		)?
		result = KaiBuild.run_in!(kai, project)
		Path.delete_all!(project)?
		result
	}

	# Test-only builds and a host-side control task, beside the example's own.
	extra =
		\\	Build("missing", [Use("dev"), Run(["true"]),
		\\		Output("dist/missing.txt")]),
		\\	Build("probe", [Use("dev"),
		\\		Run(["bash", "-c", "{ ${KaiBuild.probe}; } > probe.txt"]),
		\\		Output("probe.txt")]),
		\\	Task("probe", [Use("dev"), Run(["bash", "-c", "${KaiBuild.probe}"])]),

	# Reports whether the marker holds the token and the port connects, from
	# the marker, token and port in probe.args. Bash opens /dev/tcp itself.
	probe = "read -r marker token port < probe.args; "
		.concat("if text=$(cat -- $marker 2>/dev/null); then ")
		.concat("if [ x$text = x$token ]; then file=read; else file=wrong; fi; ")
		.concat("else file=denied; fi; ")
		.concat("if timeout 5 bash -c ': < /dev/tcp/127.0.0.1/'$port 2>/dev/null; ")
		.concat("then tcp=reachable; else tcp=denied; fi; ")
		.concat("echo host-file $file; echo host-TCP $tcp")

	run_in! = |kai, project| {
		kaifile = Path.join(project, "Kaifile.roc")
		config = match Path.read_utf8!(kaifile)?.split_on("\n]\n") {
			[body, ""] => "${body}\n${KaiBuild.extra}\n]\n"
			_ => return Err(UnexpectedKaifileEnd)
		}
		Path.write_utf8!(kaifile, config)?
		lock = Path.join(project, ".kai/lock.json")
		kai! = |args| Cmd.new(Path.to_os_str(kai)).args_str(args).cwd(project)
			.run!()
		_ = Cmd.new(Path.to_os_str(kai)).arg_str("update").cwd(project)
			.exec_output!()?
		published = Path.read_bytes!(lock)?
		modified = Path.time_modified!(lock)?
		file = |relative| Path.join(project, relative)
		# VCS metadata anywhere stays out of the snapshot.
		Path.create_all!(file("src/.git"))?
		Path.write_utf8!(file("src/.git/secret"), "excluded\n")?
		built! = |name, expected| {
			output = kai!(["build", name])?
			path = Str.from_utf8_lossy(output.stdout_bytes).trim()
			stderr = Str.from_utf8_lossy(output.stderr_bytes)
			if
				output.status != Exited(0)
					or !path.starts_with("/nix/store/")
						or !stderr.contains("built ${name}: ")
							or !stderr.contains(" -> ${path}\n")
					{
						return Err(BuildFailed(name, KaiBuild.show(output)))
					}
			actual = Path.read_utf8!(Path.utf8(path))?
			if actual != expected {
				return Err(WrongArtifact(name, actual))
			}
			Ok({})
		}
		# Refused before or during the build, never printing an artifact.
		refused! = |name, diagnostic| {
			output = kai!(["build", name])?
			stderr = Str.from_utf8_lossy(output.stderr_bytes)
			if
				output.status != Exited(1)
					or !output.stdout_bytes.is_empty()
						or stderr.contains("built ")
							or !stderr.contains(diagnostic)
					{
						return Err(NotRefused(name, diagnostic, KaiBuild.show(output)))
					}
			Ok(stderr)
		}
		library = "HELLO FROM THE WORKING TREE\n"
		built!("library", library)?
		built!("app", "Artifact example\n${library}")?
		snapshot = |relative| file(".kai/snapshot/${relative}")
		for present in ["Kaifile.roc", "src/message.txt"] {
			if !Path.is_file!(snapshot(present))? {
				return Err(MissingFromSnapshot(present))
			}
		}
		for absent in ["src/.git", "assets", ".kai"] {
			if Path.exists!(snapshot(absent))? {
				return Err(NotExcluded(absent))
			}
		}
		_ = refused!("missing", "declared output is missing: dist/missing.txt")?
		# A locked source edit fails until `kai update`; restoring it passes.
		heading = file("assets/heading.txt")
		original = Path.read_bytes!(heading)?
		Path.write_utf8!(heading, "Changed heading\n")?
		_ = refused!("app", "run `kai update`")?
		Path.write_bytes!(heading, original)?
		# Ordinary project files, even new ones, reach the next build.
		Path.write_utf8!(file("src/message.txt"), "second revision\n")?
		built!("library", "SECOND REVISION\n")?
		witness = Path.read_bytes!(file(".kai/snapshot.isolation.json"))?
		_ = Cmd.new_str("ln").args_str(["-s", "src/message.txt", "link"])
			.cwd(project).exec_output!()?
		stderr = refused!("library", "snapshot refuses symlink: ")?
		if stderr.contains("building ") {
			return Err(BuiltPastSymlink(stderr))
		}
		if Path.read_bytes!(file(".kai/snapshot.isolation.json"))? != witness {
			return Err(FailedSnapshotChangedWitness)
		}
		Path.delete!(file("link"))?
		KaiBuild.sandbox!(kai!, project, built!)?
		if
			Path.read_bytes!(lock)? != published
				or Path.time_modified!(lock)? != modified
				{
					return Err(LockChanged)
				}
		Stdout.line!(
			"kai build produced exact artifacts from fresh sandboxed snapshots",
		)
	}

	show = |output|
		Str.inspect(output.status)
			.concat("\n${Str.from_utf8_lossy(output.stdout_bytes)}")
			.concat(Str.from_utf8_lossy(output.stderr_bytes))

	# The marker sits in a world-readable directory outside HOME, so only the
	# sandbox can hide it. A listening socket completes connects on its own.
	sandbox! = |kai!, project, built!| {
		directory = Env.create_temp_dir_in!(Path.utf8("/var/tmp"), "kai-probe-")?
		result = KaiBuild.probe!(kai!, project, built!, directory)
		Path.delete_all!(directory)?
		result
	}

	probe! = |kai!, project, built!, directory| {
		_ = Cmd.new_str("chmod").args_str(["0755", Path.display(directory)])
			.exec_output!()?
		marker = Path.join(directory, "marker")
		token = Path.display(directory)
		Path.write_utf8!(marker, token)?
		listener = Tcp.listen!("127.0.0.1", 0, 5000)?
		port = listener.local_port!()?
		args = "${Path.display(marker)} ${token} ${port.to_str()}\n"
		Path.write_utf8!(Path.join(project, "probe.args"), args)?
		control = kai!(["run", "probe"])?
		reachable = "host-file read\nhost-TCP reachable\n"
		if control.stdout_bytes != reachable.to_utf8() {
			return Err(ProbeControlFailed(KaiBuild.show(control)))
		}
		built!("probe", "host-file denied\nhost-TCP denied\n")?
		listener.close!()
	}
}
