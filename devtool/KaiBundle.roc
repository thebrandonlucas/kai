# Load a Kaifile.roc from outside the repository through the platform bundle
# a release publishes: served from localhost, the bare kai a release archive
# holds checks, updates and runs it; a Nix-installed kai does the same
# offline, seeding the Roc package cache from the bundle its wrapper names.
# Each uses a fresh Roc cache, which must end up holding that bundle alone,
# so loading the platform downloads nothing else.
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import pf.Tcp

KaiBundle := [].{
	# Build a flake output and return its store path.
	nix_output! = |attribute| {
		output = Cmd.new_str("nix")
			.args_str(["build", attribute, "--no-link", "--print-out-paths"])
			.exec_output!()?
		match output.stdout_utf8.split_on("\n").keep_if(|line| !line.is_empty()) {
			[path] => Ok(Path.utf8(path))
			_ => Err(UnexpectedNixOutput({ attribute, output: output.stdout_utf8 }))
		}
	}

	names! = |dir|
		Ok(Path.list!(dir)?.map(|p| Path.display(Path.filename(p) ?? p)))

	# The platform bundle, <hash>.tar.zst, and its hash.
	platform! = || {
		store = KaiBundle.nix_output!(".#kaifile-platform")?
		names = KaiBundle.names!(store)?
		match names.keep_if(|name| name.ends_with(".tar.zst")) {
			[name] =>
				Ok({
					archive: Path.join(store, name),
					hash: name.drop_suffix(".tar.zst"),
				})
			_ => Err(UnexpectedPlatformBundle(names))
		}
	}

	kaifile = |url|
		\\app [config] { pf: platform "${url}" }
		\\
		\\config = [
		\\	Name("bundled"),
		\\	Systems(["x86_64-linux", "aarch64-linux"]),
		\\	Environment("dev", [Tools(["git"])]),
		\\	Task("version", [Use("dev"), Run(["git", "--version"])]),
		\\]
		\\

	run! = |binary| {
		kai = Path.canonicalize!(Path.utf8(binary))?
		version = Path.read_utf8!(Path.utf8("VERSION"))?.trim()
		bundle = KaiBundle.platform!()?
		installed = Path.join(KaiBundle.nix_output!(".#kai")?, "bin/kai")
		work = Path.canonicalize!(Env.create_temp_dir_with_prefix!("kai-bundle-")?)?
		result = KaiBundle.run_in!(kai, installed, bundle, version, work)
		Path.delete_all!(work)?
		result
	}

	run_in! = |kai, installed, bundle, version, work| {
		release_path = "v${version}/${bundle.hash}.tar.zst"
		archive = Path.read_bytes!(bundle.archive)?
		listener = Tcp.listen!("127.0.0.1", 0, 5000)?
		port = listener.local_port!()?
		url = "http://127.0.0.1:${port.to_str()}/${release_path}"
		target = "/${release_path}"
		served = KaiBundle.project!(
			kai,
			url,
			bundle.hash,
			Path.join(work, "served"),
			|command| KaiBundle.serving!(listener, target, archive, command),
		)
		listener.close!()?
		_ = served?
		# Unreachable, so only the seeded cache can supply the platform.
		offline = "https://kai.invalid/${release_path}"
		seeded = Path.join(work, "installed")
		KaiBundle.project!(
			installed,
			offline,
			bundle.hash,
			seeded,
			|command| Ok(command.exec_output!()?.stdout_utf8),
		)?
		Stdout.line!("kai loads the platform bundle served and pre-seeded")
	}

	# Run a command while answering its HTTP requests, one connection at a
	# time: the archive at its path, and 404 for anything else.
	serving! = |listener, path, archive, command| {
		child = command.stdout(Capture).stderr(Capture).spawn!()
			.map_err(|err| ServerFailed(Str.inspect(err)))?
		while Bool.True {
			match child.try_wait!().map_err(|err| ServerFailed(Str.inspect(err)))? {
				[{ status: Exited(0), stdout_bytes, .. }] =>
					return Ok(Str.from_utf8_lossy(stdout_bytes))
				[output] => return Err(
					KaiFailed(
						Str.inspect(output.status)
							.concat(Str.from_utf8_lossy(output.stderr_bytes)),
					),
				)
				_ => {}
			}
			match listener.accept!(100) {
				Ok(stream) => {
					_ = KaiBundle.respond!(stream, path, archive)
				}
				Err(_) => {}
			}
		}
		Err(ServerStopped)
	}

	respond! = |stream, path, archive| {
		request = stream.read_line!(8192, 5000)?
		var $header = request
		while $header != "\r\n" and $header != "\n" and $header != "" {
			$header = stream.read_line!(8192, 5000)?
		}
		(status, body) = match request.split_on(" ") {
			["GET", target, ..] if target == path => ("200 OK", archive)
			_ => ("404 Not Found", [])
		}
		head = "HTTP/1.1 ${status}\r\nContent-Length: ${body.len().to_str()}"
			.concat("\r\nConnection: close\r\n\r\n")
		stream.write!(head.to_utf8().concat(body), 30000)
	}

	# A fresh project and Roc cache (Nix keeps the caller's) whose check must
	# leave only the bundle cached: no other package, no staging directory.
	project! = |kai, url, hash, dir, execute!| {
		cache = Path.join(dir, "cache")
		Path.create_all!(cache)?
		nix_cache = match Env.var_str!("XDG_CACHE_HOME") {
			Ok(value) if !value.is_empty() => "${value}/nix"
			_ => {
				home = Env.var_str!("HOME")?
				"${home}/.cache/nix"
			}
		}
		link = Path.display(Path.join(cache, "nix"))
		Cmd.new_str("ln").args_str(["-s", nix_cache, link]).exec_cmd!()?
		Path.write_utf8!(Path.join(dir, "Kaifile.roc"), KaiBundle.kaifile(url))?
		kai! = |args| execute!(
			Cmd.new(Path.to_os_str(kai)).args_str(args).cwd(dir)
				.env(OsStr.utf8("XDG_CACHE_HOME"), Path.to_os_str(cache)),
		)
		_ = kai!(["check"])?
		roc_packages = Path.join(cache, "roc/packages")
		cached = KaiBundle.names!(roc_packages)?
		bundled = |name| name == hash or name == "${hash}.deps.json"
		if !cached.contains(hash) or !cached.all(bundled) {
			return Err(UnexpectedRocCache(cached))
		}
		_ = kai!(["update"])?
		output = kai!(["run", "version"])?
		if !output.starts_with("git version ") {
			return Err(WrongTaskOutput(output))
		}
		Ok({})
	}
}
