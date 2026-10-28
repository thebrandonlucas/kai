# kai build. On Nix, on a copy of the artifacts fixture: artifacts have exact
# bytes, every build snapshots the project afresh, a missing output or
# symlink never reports success, a changed locked source needs `kai update`,
# the sandbox hides host files and TCP, and the lock is never written. On
# Guix, on a copy of the channels fixture with Nix off PATH: a sandboxed build
# prints the store path of its exact artifact, a build reads a locked source,
# and a changed locked source needs `kai update`.
import pf.Cmd
import pf.Duration
import pf.Env
import pf.Path
import pf.Stdout
import pf.Tcp

import Exec

import E2e

E2eBuild := [].{
	nix! = |binary| {
		(kai, project) = E2e.nix_fixture!(
			binary,
			"artifacts",
			["assets", "src"],
		)?
		result = E2eBuild.nix_in!(kai, project)
		Path.delete_all!(project)?
		result
	}

	# Test-only builds and a host-side control task, beside the example's own.
	extra =
		\\	Build("missing", [Use("dev"), Run(["true"]),
		\\		Output("dist/missing.txt")]),
		\\	Build("probe", [Use("dev"),
		\\		Run(["bash", "-c", "{ ${E2eBuild.probe}; } > probe.txt"]),
		\\		Output("probe.txt")]),
		\\	Task("probe", [Use("dev"), Run(["bash", "-c", "${E2eBuild.probe}"])]),

	# Reports whether the marker holds the token and the port connects, from
	# the marker, token and port in probe.args. Bash opens /dev/tcp itself.
	probe = "read -r marker token port < probe.args; "
		.concat("if text=$(cat -- $marker 2>/dev/null); then ")
		.concat("if [ x$text = x$token ]; then file=read; else file=wrong; fi; ")
		.concat("else file=denied; fi; ")
		.concat("if timeout 5 bash -c ': < /dev/tcp/127.0.0.1/'$port 2>/dev/null; ")
		.concat("then tcp=reachable; else tcp=denied; fi; ")
		.concat("echo host-file $file; echo host-TCP $tcp")

	nix_in! = |kai, project| {
		kaifile = Path.join(project, "Kaifile.roc")
		config = match Path.read_utf8!(kaifile)?.split_on("\n])\n") {
			[body, ""] => "${body}\n${E2eBuild.extra}\n])\n"
			_ => return Err(UnexpectedKaifileEnd)
		}
		Path.write_utf8!(kaifile, config)?
		lock = Path.join(project, ".kai/lock.json")
		kai! = |args| Cmd.new(Path.to_os_str(kai)).args(Exec.strs(args)).cwd(project)
			.run!()
		_ = Exec.output!(Cmd.new(Path.to_os_str(kai)).arg("update").cwd(project))?
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
						return Err(BuildFailed(name, E2eBuild.show(output)))
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
						return Err(NotRefused(name, diagnostic, E2eBuild.show(output)))
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
		_ = refused!("app", "run `kai update assets`")?
		Path.write_bytes!(heading, original)?
		# Ordinary project files, even new ones, reach the next build.
		Path.write_utf8!(file("src/message.txt"), "second revision\n")?
		built!("library", "SECOND REVISION\n")?
		witness = Path.read_bytes!(file(".kai/snapshot.isolation.json"))?
		_ = Exec.output!(
			Exec.cmd("ln").args(Exec.strs(["-s", "src/message.txt", "link"]))
				.cwd(project),
		)?
		stderr = refused!("library", "snapshot refuses symlink: ")?
		if stderr.contains("building ") {
			return Err(BuiltPastSymlink(stderr))
		}
		if Path.read_bytes!(file(".kai/snapshot.isolation.json"))? != witness {
			return Err(FailedSnapshotChangedWitness)
		}
		Path.delete!(file("link"))?
		E2eBuild.sandbox!(kai!, project, built!)?
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
		result = E2eBuild.probe!(kai!, project, built!, directory)
		Path.delete_all!(directory)?
		result
	}

	probe! = |kai!, project, built!, directory| {
		mode = Exec.cmd("chmod").args(Exec.strs(["0755", Path.display(directory)]))
		_ = Exec.output!(mode)?
		marker = Path.join(directory, "marker")
		token = Path.display(directory)
		Path.write_utf8!(marker, token)?
		listener = Tcp.listen!("127.0.0.1", 0, Duration.millis(5000))?
		port = listener.local_port!()?
		args = "${Path.display(marker)} ${token} ${port.to_str()}\n"
		Path.write_utf8!(Path.join(project, "probe.args"), args)?
		control = kai!(["run", "probe"])?
		reachable = "host-file read\nhost-TCP reachable\n"
		if control.stdout_bytes != reachable.to_utf8() {
			return Err(ProbeControlFailed(E2eBuild.show(control)))
		}
		built!("probe", "host-file denied\nhost-TCP denied\n")?
		listener.close!()
	}

	guix! = |bare, guix|
		match guix {
			Missing => E2e.skipped!("kai build")
			Ready(path) => {
				(kai, project) = E2e.guix_project!(bare, "channels", ["words"])?
				result = E2eBuild.guix_in!(kai, project, path)
				Path.delete_all!(project)?
				result
			}
		}

	guix_in! = |kai, project, path| {
		args = ["--backend", "guix", "build", "greeting"]
		built = E2e.guix_kai!(kai, project, path, args)?
		store = built.stdout_utf8.trim()
		if !store.ends_with("-kai-greeting") {
			return Err(WrongGuixBuild(Str.inspect(built)))
		}
		if Path.read_utf8!(Path.utf8(store))? != "Hello, world!\n" {
			return Err(WrongGuixArtifact(store))
		}
		# Lock the source beside the release pin, as `kai update` would.
		words = Path.join(project, "words")
		guix = Path.to_os_str(Path.join(path, "guix"))
		nar = ["hash", "-S", "nar", Path.display(words)]
		hash = Exec.output!(Cmd.new(guix).args(Exec.strs(nar)))?.stdout_utf8.trim()
		source = "{\"name\": \"words\", \"path\": \"words\", \"hash\": \"${hash}\"}"
		lock = E2e.lock(E2e.release)
			.drop_suffix("}}\n")
			.concat(",\n  \"sources\": [${source}]\n}}\n")
		Path.write_utf8!(Path.join(project, ".kai/lock.json"), lock)?
		quote = ["--backend", "guix", "build", "quote"]
		quoted = E2e.guix_kai!(kai, project, path, quote)?.stdout_utf8.trim()
		if Path.read_utf8!(Path.utf8(quoted))? != "Hello from a locked source\n" {
			return Err(WrongGuixArtifact(quoted))
		}
		# A locked source edit fails until `kai update`.
		Path.write_utf8!(Path.join(words, "greeting.txt"), "changed\n")?
		match E2e.guix_kai!(kai, project, path, quote) {
			Err(NonZeroExitCode({ stderr_utf8_lossy, .. }))
			if stderr_utf8_lossy.contains("run `kai --backend guix update`") => {}
			other => return Err(GuixBuiltChangedSource(Str.inspect(other)))
		}
		Stdout.line!("kai built exact artifacts, one from a source, on Guix")
	}
}
