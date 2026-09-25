# Load a Kaifile.roc from outside the repository through the platform bundle
# a release publishes: served from localhost, the bare kai a release archive
# holds checks, updates and runs it; a Nix-installed kai does the same
# offline, from the Roc package cache its wrapper seeds. Each uses a fresh Roc
# cache.
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout

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
		\\	Systems(["x86_64-linux"]),
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
		Path.create_all!(Path.join(work, "serve/v${version}"))?
		Path.copy!(bundle.archive, Path.join(work, "serve/${release_path}"))?
		server = Cmd.new_str("python3")
			.args_str(["-u", "-m", "http.server", "0", "--bind", "127.0.0.1"])
			.cwd(Path.join(work, "serve"))
			.stdout(Pipe)
			.stderr(Null)
			.spawn!() ? ServerFailed
		served = KaiBundle.serve!(server, kai, bundle.hash, release_path, work)
		server.close!() ? ServerFailed
		_ = served?
		# Unreachable, so only the seeded cache can supply the platform.
		offline = "https://kai.invalid/${release_path}"
		seeded = Path.join(work, "installed")
		KaiBundle.project!(installed, offline, bundle.hash, seeded)?
		Stdout.line!("kai loads the platform bundle served and pre-seeded")
	}

	serve! = |server, kai, hash, release_path, work| {
		# "Serving HTTP on 127.0.0.1 port <port> (http://...) ..."
		port = match server.read!(4096, 10000) ? ServerFailed {
			Stdout(bytes) =>
				match Str.from_utf8_lossy(bytes).split_on(" port ") {
					[_, rest] => rest.split_on(" ").first() ?? ""
					_ => ""
				}
			_ => ""
		}
		if port.is_empty() {
			return Err(ServerDidNotStart)
		}
		url = "http://127.0.0.1:${port}/${release_path}"
		KaiBundle.project!(kai, url, hash, Path.join(work, "served"))
	}

	# A fresh project and Roc cache (Nix keeps the caller's) whose check must
	# leave the bundle cached, with no staging directories behind.
	project! = |kai, url, hash, dir| {
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
		kai! = |args| Cmd.new(Path.to_os_str(kai)).args_str(args).cwd(dir)
			.env(OsStr.utf8("XDG_CACHE_HOME"), Path.to_os_str(cache))
			.exec_output!()
		_ = kai!(["check"])?
		roc_packages = Path.join(cache, "roc/packages")
		cached = KaiBundle.names!(roc_packages)?
		if !cached.contains(hash) or cached.any(|name| name.ends_with(".tmp")) {
			return Err(UnexpectedRocCache(cached))
		}
		_ = kai!(["update"])?
		output = kai!(["run", "version"])?
		if !output.stdout_utf8.starts_with("git version ") {
			return Err(WrongTaskOutput(output.stdout_utf8))
		}
		Ok({})
	}
}
