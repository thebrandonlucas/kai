# Blu's effects: the content-addressed store, fetches, bwrap builds, profiles
# and the collector. Host tools do what basic-cli cannot: hash, tar and link.
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stderr

import Recipe

## HOME holds store/, db/, profiles/ and tmp/; PKGS holds NAME.blu recipes.
Store := { home : Str, pkgs : Str }.{

	load! : Store, Str => Try(Recipe, _)
	load! = |store, name| {
		text = Path.unix("${store.pkgs}/${name}.blu").read_utf8!()?
		Recipe.parse(text).map_err(|message| BadRecipe(name, message))
	}

	## Realise RECIPE after its inputs, reusing a cached realisation while its
	## output is still stored.
	realise! : Store, Recipe, List(Str) => Try(Str, _)
	realise! = |store, recipe, seen| {
		if seen.contains(recipe.name) {
			return Err(Cycle(recipe.name))
		}
		var $inputs = []
		for name in recipe.inputs {
			input = Store.load!(store, name)?
			path = Store.realise!(store, input, seen.append(recipe.name))?
			$inputs = $inputs.append((name, path))
		}
		paths = $inputs.map(|(_, path)| path)
		key = Store.sha256!(Recipe.key(recipe, paths))?
		cached = Store.at(store, "db/realisations/${key}")
		hit = cached.read_utf8!() ?? ""
		if !hit.is_empty() and Store.exists!(hit) {
			return Ok(hit)
		}
		tmp = Store.scratch!(store)?
		out = "${tmp}/out"
		Path.unix(out).create_dir!()?
		match recipe.build {
			Fetch(fetch) => Store.fetch!(fetch, out)?
			Run(argv) => {
				at_tmp = ["--chdir", "/tmp"]
				Store.sandbox!(store, $inputs, out, at_tmp, argv)?
			}
			Union => Store.union!(paths, out)?
			Project({ source, run, output }) => {
				work = "${tmp}/build"
				_ = Store.host!("cp", ["-R", source, work])?
				_ = Store.host!("chmod", ["-R", "u+w", work])?
				at_work = ["--bind", work, "/build", "--chdir", "/build"]
				Store.sandbox!(store, $inputs, out, at_work, run)?
				_ = Store.host!("cp", ["-R", "--", "${work}/${output}", out])?
			}
		}
		path = Store.add!(store, out, recipe.name, paths)?
		Store.remove!(tmp)?
		Store.at(store, "db/realisations").create_all!()?
		cached.write_utf8!(path)?
		Ok(path)
	}

	## Copy a project directory into the store, without VCS or Kai state.
	import! : Store, Str, Str => Try(Str, _)
	import! = |store, root, name| {
		tmp = Store.scratch!(store)?
		out = "${tmp}/out"
		Path.unix(out).create_dir!()?
		copy =
			\\set -o pipefail
			\\tar -C "$1" --exclude=./.git --exclude=./.kai -cf - . |
			\\  tar -C "$2" -xf -
		_ = Store.host!("sh", ["-c", copy, "sh", root, out])?
		path = Store.add!(store, out, name, [])?
		Store.remove!(tmp)?
		Ok(path)
	}

	## Store OUT under the hash of its normalized tar stream; an equal output
	## already stored is reused, which is what content addressing buys.
	add! : Store, Str, Str, List(Str) => Try(Str, _)
	add! = |store, out, name, refs| {
		tar =
			\\set -o pipefail
			\\flags="--sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner"
			\\tar $flags --mode=a-w --format=gnu -C "$1" -cf - . | sha256sum
		hash = Store.host!("sh", ["-c", tar, "sh", out])?
		base = "${prefix(hash, 32)}-${name}"
		path = "${store.home}/store/${base}"
		if Store.exists!(path) {
			Store.remove!(out)?
		} else {
			Store.at(store, "store").create_all!()?
			Path.unix(out).rename!(Path.unix(path))?
			_ = Store.host!("chmod", ["-R", "a-w", path])?
		}
		Store.at(store, "db/refs").create_all!()?
		Store.at(store, "db/refs/${base}").write_utf8!(Str.join_with(refs, "\n"))?
		Ok(path)
	}

	## Download to OUT/PATH and accept it only with the declared hash.
	fetch! : { url : Str, sha256 : Str, path : Str }, Str => Try({}, _)
	fetch! = |{ url, sha256, path }, out| {
		file = "${out}/${path}"
		_ = Store.host!("curl", ["-fsSL", "--create-dirs", "-o", file, url])?
		actual = prefix(Store.host!("sha256sum", [file])?, 64)
		if actual != sha256 {
			return Err(HashMismatch(url, actual))
		}
		_ = Store.host!("chmod", ["a+x", file])?
		Ok({})
	}

	## Run ARGV with only the inputs' closure visible and no network. $out is
	## /out, so outputs must not refer to themselves.
	sandbox! : Store, List((Str, Str)), Str, List(Str), List(Str) => Try({}, _)
	sandbox! = |store, inputs, out, extra, argv| {
		paths = inputs.map(|(_, path)| path)
		visible = Store.closure!(store, paths, [])?
		isolated = [
			"--unshare-all",
			"--die-with-parent",
			"--clearenv",
			"--proc",
			"/proc",
			"--dev",
			"/dev",
			"--tmpfs",
			"/tmp",
			"--bind",
			out,
			"/out",
			"--setenv",
			"out",
			"/out",
			"--setenv",
			"PATH",
			Str.join_with(paths.map(|p| "${p}/bin"), ":"),
		]
		named = inputs.fold(
			[],
			|acc, (name, path)| acc.concat(["--setenv", name, path]),
		)
		bound = visible.fold(
			[],
			|acc, path| acc.concat(["--ro-bind", path, path]),
		)
		args = isolated.concat(named).concat(bound).concat(extra)
		Stderr.write!(Store.host!("bwrap", args.concat(["--"]).concat(argv))?)
	}

	## Link every input's bin entries into OUT/bin; the first input wins a name.
	union! : List(Str), Str => Try({}, _)
	union! = |paths, out| {
		Path.unix("${out}/bin").create_dir!()?
		for input in paths {
			for entry in Path.unix("${input}/bin").list!() ?? [] {
				source = entry.display()
				link = "${out}/bin/${source.split_on("/").last() ?? ""}"
				if !Store.exists!(link) {
					_ = Store.host!("ln", ["-s", source, link])?
				}
			}
		}
		Ok({})
	}

	## PATHS and everything they reference, from the recorded direct inputs.
	closure! : Store, List(Str), List(Str) => Try(List(Str), _)
	closure! = |store, todo, seen|
		match todo {
			[] => Ok(seen)
			[path, .. as rest] if seen.contains(path) =>
				Store.closure!(store, rest, seen)
			[path, .. as rest] => {
				refs = Store.refs(store, path).read_utf8!() ?? ""
				direct = refs.split_on("\n").keep_if(|r| !r.is_empty())
				Store.closure!(store, rest.concat(direct), seen.append(path))
			}
		}

	## Generation N is the symlink profiles/N; profiles/current links to one.
	generations! : Store => Try({ current : U64, list : List((U64, Str)) }, _)
	generations! = |store| {
		dir = "${store.home}/profiles"
		var $list = []
		var $n = 1
		while Store.exists!("${dir}/${$n.to_str()}") {
			target = Store.host!("readlink", ["${dir}/${$n.to_str()}"])?
			$list = $list.append(($n, target))
			$n = $n + 1
		}
		current =
			if $list.is_empty() {
				0
			} else {
				U64.from_str(Store.host!("readlink", ["${dir}/current"])?) ?? 0
			}
		Ok({ current, list: $list })
	}

	switch! : Store, Str => Try((U64, Str), _)
	switch! = |store, path| {
		n = Store.generations!(store)?.list.len() + 1
		dir = "${store.home}/profiles"
		Path.unix(dir).create_all!()?
		_ = Store.host!("ln", ["-s", path, "${dir}/${n.to_str()}"])?
		Store.point!(store, n)?
		Ok((n, path))
	}

	rollback! : Store => Try((U64, Str), _)
	rollback! = |store| {
		{ current, list } = Store.generations!(store)?
		if current < 2 {
			return Err(NoPreviousGeneration)
		}
		previous = list.get(current - 2).map_err(|_| NoPreviousGeneration)?
		Store.point!(store, previous.0)?
		Ok(previous)
	}

	## Replace profiles/current with one rename, so readers never see a gap.
	point! : Store, U64 => Try({}, _)
	point! = |store, n| {
		dir = "${store.home}/profiles"
		_ = Store.host!("ln", ["-sfn", n.to_str(), "${dir}/current.new"])?
		Path.unix("${dir}/current.new").rename!(Path.unix("${dir}/current"))
	}

	## Delete every stored path outside the closure of all generations.
	gc! : Store => Try(List(Str), _)
	gc! = |store| {
		roots = Store.generations!(store)?.list.map(|(_, path)| path)
		live = Store.closure!(store, roots, [])?
		var $deleted = []
		for entry in Store.at(store, "store").list!() ?? [] {
			path = entry.display()
			if !live.contains(path) {
				Store.remove!(path)?
				Store.refs(store, path).delete!()?
				$deleted = $deleted.append(path)
			}
		}
		Ok($deleted)
	}

	sha256! : Str => Try(Str, _)
	sha256! = |text| {
		output = Cmd.new_str("sha256sum")
			.stdin(Bytes(text.to_utf8()))
			.stderr(Inherit)
			.run!()?
		Ok(prefix(Str.from_utf8_lossy(output.stdout_bytes), 64))
	}

	scratch! : Store => Try(Str, _)
	scratch! = |store| {
		Store.at(store, "tmp").create_all!()?
		Ok(Env.create_temp_dir_in!(Store.at(store, "tmp"), "blu-")?.display())
	}

	## Stored trees are read-only, so make them writable before deleting.
	remove! : Str => Try({}, _)
	remove! = |path| {
		_ = Store.host!("chmod", ["-R", "u+w", path])?
		Path.unix(path).delete_all!()
	}

	exists! : Str => Bool
	exists! = |path| Path.unix(path).exists!() ?? Bool.False

	## Run a host tool and return its trimmed stdout; its stderr passes through.
	host! : Str, List(Str) => Try(Str, _)
	host! = |program, args| {
		output = Cmd.new_str(program).args_str(args).stderr(Inherit).run!()?
		match output.status {
			Exited(0) => Ok(Str.from_utf8_lossy(output.stdout_bytes).trim())
			_ => Err(HostFailed(program))
		}
	}

	at : Store, Str -> Path
	at = |store, relative| Path.unix("${store.home}/${relative}")

	## A stored path's direct inputs, one per line.
	refs : Store, Str -> Path
	refs = |store, path|
		Store.at(store, "db/refs/${path.drop_prefix("${store.home}/store/")}")
}

prefix : Str, U64 -> Str
prefix = |text, count| Str.from_utf8_lossy(text.to_utf8().take_first(count))
