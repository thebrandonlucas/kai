# Load a Kaifile.roc from outside the repository through the platform and std
# bundles a release publishes: served from localhost, the bare kai a release
# archive holds checks, updates and runs it; a Nix-installed kai does the
# same offline, seeding the Roc package cache from the bundles its wrapper
# names. Each uses a fresh Roc cache, which must end up holding exactly those
# two bundles and the packages the platform imports. A std bundled against
# another platform is refused.
import pf.Cmd
import pf.Duration
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import pf.Tcp

import Exec

import Bundles

E2eBundle := [].{
	# The URL packages the platform imports: Weaver, and the ansi and path
	# packages Weaver imports (the flake's rocPackages).
	platform_packages = [
		"7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77",
		"JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL",
		"7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE",
	]

	kaifile = |pf_url, std|
		\\app [kaifile] {
		\\	pf: platform "${pf_url}",
		\\	std: "${std}",
		\\}
		\\
		\\import std.Std
		\\
		\\kaifile = Std.kaifile([
		\\	Name("bundled"),
		\\	Systems(["x86_64-linux", "aarch64-linux"]),
		\\	Environment("dev", [Tools(["git"])]),
		\\	Task("version", [Use("dev"), Run(["git", "--version"])]),
		\\])
		\\

	# The platform URL a std bundle's header names.
	platform_url! = |std| {
		header = Path.read_utf8!(Path.join(std.unpacked, "main.roc"))?
		match header.split_on("pf: platform \"") {
			[_, rest] => Ok(rest.split_on("\"").first() ?? "")
			_ => Err(NoPlatformInStd(header))
		}
	}

	# std bundled against the platform at `url`, as the flake bundles it
	# against the release URL. roc bundle resolves the platform, so its cache
	# holds the unpacked platform bundle.
	std_for! = |url, pf_bundle, work| {
		source = Path.join(work, "std")
		output = Path.join(work, "std-bundle")
		store = Path.join(work, "bundle-cache/roc/packages")
		Path.create_all!(output)?
		Path.create_all!(store)?
		copy! = |from, to|
			Exec.cmd!(
				Exec.cmd("cp")
					.args(Exec.strs(["-R", "--no-preserve=mode", "--"]))
					.args(Exec.strs([from, Path.display(to)])),
			)
		copy!(Path.display(pf_bundle.unpacked), Path.join(store, pf_bundle.hash))?
		copy!("plugins/std", source)?
		rewrite! = |file, from, to|
			Path.write_utf8!(file, Path.read_utf8!(file)?.replace_each(from, to))
		main = Path.join(source, "main.roc")
		rewrite!(main, "\"../../platform/main.roc\"", "\"${url}\"")?
		# std's own packages reach the platform's modules through api.roc;
		# bundled, they depend on the platform release itself.
		nested = [
			("model", "../../../platform/api.roc"),
			("backends/nix", "../../../../platform/api.roc"),
			("backends/guix", "../../../../platform/api.roc"),
		]
		for (dir, api) in nested {
			fuzz = Path.join(source, "${dir}/fuzz")
			if Path.exists!(fuzz)? {
				Path.delete_all!(fuzz)?
			}
			rewrite!(
				Path.join(source, "${dir}/main.roc"),
				"api: \"${api}\"",
				"api: platform \"${url}\"",
			)?
		}
		listed = Exec.output!(
			Exec.cmd("find")
				.args(Exec.strs([".", "-type", "f", "!", "-path", "./main.roc"]))
				.cwd(source),
		)?
		files = listed.stdout_utf8.split_on("\n").keep_if(|f| !f.is_empty())
		_ = Exec.output!(
			Exec.cmd("roc")
				.args(Exec.strs(["bundle", "main.roc"]))
				.args(Exec.strs(files))
				.args(Exec.strs(["--output-dir", Path.display(output)]))
				.cwd(source)
				.env(
					OsStr.utf8("XDG_CACHE_HOME"),
					Path.to_os_str(Path.join(work, "bundle-cache")),
				),
		)?
		Bundles.found!(output, "std for ${url}")
	}

	nix! = |binary| {
		kai = Path.canonicalize!(Path.utf8(binary))?
		version = Path.read_utf8!(Path.utf8("VERSION"))?.trim()
		pf_bundle = Bundles.platform!()?
		std = Bundles.bundle!(".#kai-std")?
		installed = Path.join(Bundles.nix_output!(".#kai")?, "bin/kai")
		work = Path.canonicalize!(Env.create_temp_dir_with_prefix!("kai-bundle-")?)?
		result = E2eBundle.run_in!(kai, installed, pf_bundle, std, version, work)
		Path.delete_all!(work)?
		result
	}

	run_in! = |kai, installed, pf_bundle, std, version, work| {
		listener = Tcp.listen!("127.0.0.1", 0, Duration.millis(5000))?
		base = "http://127.0.0.1:${listener.local_port!()?.to_str()}"
		path = |hash| "/v${version}/${hash}.tar.zst"
		# Roc tells packages apart by URL minus version and hash, so std's
		# asset name carries a prefix.
		std_path = |hash| "/v${version}/std-${hash}.tar.zst"
		platform_url = "${base}${path(pf_bundle.hash)}"
		served_std = E2eBundle.std_for!(platform_url, pf_bundle, work)?
		routes = [
			(path(pf_bundle.hash), Path.read_bytes!(pf_bundle.archive)?),
			(std_path(served_std.hash), Path.read_bytes!(served_std.archive)?),
			(std_path(std.hash), Path.read_bytes!(std.archive)?),
		]
		serve! = |command| E2eBundle.serving!(listener, routes, command)
		served = E2eBundle.project!(
			kai,
			E2eBundle.kaifile(platform_url, "${base}${std_path(served_std.hash)}"),
			[pf_bundle.hash, served_std.hash].concat(E2eBundle.platform_packages),
			Path.join(work, "served"),
			serve!,
		)
		# The released std names the release's platform URL, not this one.
		mismatched = E2eBundle.mismatch!(
			kai,
			E2eBundle.kaifile(platform_url, "${base}${std_path(std.hash)}"),
			Path.join(work, "mismatched"),
			serve!,
		)
		listener.close!()?
		_ = served?
		_ = mismatched?
		# Unreachable, so only the seeded cache can supply std; the platform
		# URL must be the one std names, which is not published yet.
		E2eBundle.project!(
			installed,
			E2eBundle.kaifile(
				E2eBundle.platform_url!(std)?,
				"https://kai.invalid${std_path(std.hash)}",
			),
			[pf_bundle.hash, std.hash].concat(E2eBundle.platform_packages),
			Path.join(work, "installed"),
			|command| Ok(Exec.output!(command)?.stdout_utf8),
		)?
		Stdout.line!("kai loads the platform and std bundles served and pre-seeded")
	}

	# Run a command while answering its HTTP requests, one connection at a
	# time: each archive at its path, and 404 for anything else.
	serving! = |listener, routes, command| {
		child = command.stdout(Capture).stderr(Capture).spawn!()
			.map_err(|err| ServerFailed(Str.inspect(err)))?
		while Bool.True {
			match child.poll!().map_err(|err| ServerFailed(Str.inspect(err)))? {
				Finished(output) if output.status == Exited(0) =>
					return Ok(Str.from_utf8_lossy(output.stdout_bytes))
				Finished(output) => return Err(
					KaiFailed(
						Str.inspect(output.status)
							.concat(Str.from_utf8_lossy(output.stderr_bytes)),
					),
				)
				Running => {}
			}
			waiting = {
				accept_timeout: After(Duration.millis(100)),
				io_timeout: Duration.seconds(30),
			}
			match listener.accept!(waiting) {
				Ok(stream) => {
					_ = E2eBundle.respond!(stream, routes)
				}
				Err(_) => {}
			}
		}
	}

	respond! = |stream, routes| {
		connection = stream.with_line_limit(8192)
		request = connection.read_line!()?
		# Headers end at the first blank line, however its ending is trimmed.
		var $header = request
		while $header.trim() != "" {
			$header = connection.read_line!()?
		}
		target = match request.split_on(" ") {
			["GET", path, ..] => path
			_ => ""
		}
		(status, body) = match routes.find_first(|(path, _)| path == target) {
			Ok((_, archive)) => ("200 OK", archive)
			Err(_) => ("404 Not Found", [])
		}
		head = "HTTP/1.1 ${status}\r\nContent-Length: ${body.len().to_str()}"
			.concat("\r\nConnection: close\r\n\r\n")
		connection.write_bytes!(head.to_utf8().concat(body))
	}

	# A fresh project and Roc cache; Nix keeps the caller's cache.
	fresh! = |dir, text| {
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
		Exec.cmd!(Exec.cmd("ln").args(Exec.strs(["-s", nix_cache, link])))?
		Path.write_utf8!(Path.join(dir, "Kaifile.roc"), text)?
		Ok(cache)
	}

	# A check that must leave exactly the expected bundles cached (no other
	# package, no staging directory), then an update and a task.
	project! = |kai, text, hashes, dir, execute!| {
		cache = E2eBundle.fresh!(dir, text)?
		kai! = |args| execute!(
			Cmd.new(Path.to_os_str(kai)).args(Exec.strs(args)).cwd(dir)
				.env(OsStr.utf8("XDG_CACHE_HOME"), Path.to_os_str(cache)),
		)
		_ = kai!(["check"])?
		roc_packages = Path.join(cache, "roc/packages")
		cached = Bundles.names!(roc_packages)?
		bundled = |name| hashes.any(|h| name == h or name == "${h}.deps.json")
		if !hashes.all(|h| cached.contains(h)) or !cached.all(bundled) {
			return Err(UnexpectedRocCache(cached))
		}
		# Guix would clone its channel into this fresh cache; bundles are Nix's.
		_ = kai!(["--backend", "nix", "update"])?
		output = kai!(["run", "version"])?
		if !output.starts_with("git version ") {
			return Err(WrongTaskOutput(output))
		}
		Ok({})
	}

	# roc refuses a std pinned to another platform before type checking.
	mismatch! = |kai, text, dir, execute!| {
		cache = E2eBundle.fresh!(dir, text)?
		checked = execute!(
			Cmd.new(Path.to_os_str(kai)).args(Exec.strs(["check"])).cwd(dir)
				.env(OsStr.utf8("XDG_CACHE_HOME"), Path.to_os_str(cache)),
		)
		match checked {
			Err(KaiFailed(output)) if output.contains("platform dependency mismatch") =>
				Ok({})
			other => Err(MismatchNotRefused(Str.inspect(other)))
		}
	}
}
