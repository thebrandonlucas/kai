# kai's store of pinned downloads, named by content under the cache directory:
#
#     <cache>/kai/v1/artifacts/sha256/<hex>     the downloaded bytes
#     <cache>/kai/v1/trees/sha256/<hex>         an archive, unpacked whole
#
# An artifact is hashed again before every use, and one that is not what its
# name says is removed with its tree and downloaded again. Everything is made
# under a fresh name beside its final one and renamed into place, so two kais
# making the same thing both succeed. Downloads are HTTPS, send no credentials
# and are held in memory while they are hashed. The store may be deleted at
# any time.
#
# Adapted from Store.roc and Download.roc of roc-blueprint
# (https://github.com/lukewilliamboswell/roc-blueprint), Copyright (c) 2026
# Luke Boswell and subsequent authors, under the Universal Permissive License
# (UPL), Version 1.0.
import pf.Cmd
import pf.Env
import pf.File
import pf.Http
import pf.OsStr
import pf.Path
import pf.Random
import pf.Sleep

import api.Plan

import http.Request
import http.Response

import Output
import Workspace

Store := [].{
	under : Str, Str -> Str
	under = |cache, kind| "${cache}/kai/v1/${kind}/sha256"

	# Why a program in a plan cannot be downloaded safely, before any is.
	check : Plan.Program -> Try({}, Str)
	check = |program| {
		{ name, urls, sha256, size, unpack } = program
		hex = |b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f')
		digest = sha256.count_utf8_bytes() == 64 and sha256.to_utf8().all(hex)
		inner = match unpack {
			File => "file"
			Archive(path) => path
		}
		if ["", ".", ".."].contains(name) or name.contains("/") {
			Err("not a program name: ${name}")
		} else if !digest or size == 0 {
			Err("${name} has no SHA-256 and size")
		} else if inner.starts_with("/") or inner.split_on("/").contains("..") {
			Err("${name} lies outside its archive: ${inner}")
		} else {
			Store.check_urls(name, urls)
		}
	}

	check_urls : Str, List(Str) -> Try({}, Str)
	check_urls = |name, urls|
		if urls.is_empty() {
			Err("${name} has no URL")
		} else if urls.all(|url| url.starts_with("https://")) {
			Ok({})
		} else {
			Err("${name} is downloaded over more than HTTPS")
		}

	# Make `programs` ready and link each into `bin`, which then holds no
	# other program.
	expose! :
		Str, { bin : Str, programs : List(Plan.Program) }, Output.Mode => Try({}, _)
	expose! = |cache, { bin, programs }, mode| {
		Workspace.safe_path!(bin)?
		Workspace.path(bin).create_all!()?
		kept = programs.map(|program| "${bin}/${program.name}")
		for entry in Workspace.path(bin).list!()? {
			name = entry.to_str()?
			if !kept.contains(name) and !name.ends_with(".tmp") {
				entry.delete!()?
			}
		}
		for program in programs {
			target = Store.realise!(cache, program, mode)?
			link = "${bin}/${program.name}"
			staged = "${link}.${Random.seed_u64!()?.to_str()}.tmp"
			Path.symlink!(Workspace.path(target), Workspace.path(staged), File)?
			Workspace.path(staged).rename!(Workspace.path(link))?
		}
		Ok({})
	}

	# The file that is `program`: its artifact verified now, downloaded if
	# need be, and its archive unpacked if it is not yet.
	realise! : Str, Plan.Program, Output.Mode => Try(Str, _)
	realise! = |cache, program, mode| {
		cache_absolute = cache.starts_with("/")
		if !cache_absolute {
			return Err(StoreFailed("the cache directory ${cache} is not absolute"))
		}
		{ name, sha256, .. } = program
		artifact = "${Store.under(cache, "artifacts")}/${sha256}"
		tree = "${Store.under(cache, "trees")}/${sha256}"
		stored = Workspace.path(artifact).is_file!() ?? Bool.False
		if !stored or Store.digest!(artifact)? != sha256 {
			_ = Workspace.path(artifact).delete!()
			_ = Workspace.path(tree).delete_all!()
			accept = |bytes| Store.verified(program, bytes)
			bytes = Store.served!(name, program.urls, accept, mode)?
			Store.keep!(artifact, bytes)?
		}
		match program.unpack {
			File => {
				_ = Store.tool!("chmod", ["0555", artifact], "make ${name} executable")?
				Ok(artifact)
			}
			Archive(inside) => {
				if !(Workspace.path(tree).is_dir!() ?? Bool.False) {
					Store.unpack!(artifact, tree, name)?
				}
				file = "${tree}/${Store.clean(inside)}"
				if Workspace.path(file).is_file!() ?? Bool.False {
					Ok(file)
				} else {
					Err(StoreFailed("the archive for ${name} holds no ${inside}"))
				}
			}
		}
	}

	# The digest and length of what the first of `urls` serves, kept in the
	# store so that the run after it need not download it again.
	measure! :
		Str, Str, List(Str), Output.Mode => Try({ sha256 : Str, size : U64 }, _)
	measure! = |cache, name, urls, mode| {
		bytes = Store.served!(name, urls, |_| Ok({}), mode)?
		sha256 = Crypto.SHA256.hash(bytes).to_hex()
		Store.keep!("${Store.under(cache, "artifacts")}/${sha256}", bytes)?
		Ok({ sha256, size: bytes.len() })
	}

	verified : Plan.Program, List(U8) -> Try({}, Str)
	verified = |{ sha256, size, .. }, bytes| {
		actual = Crypto.SHA256.hash(bytes).to_hex()
		if bytes.len() != size {
			Err("it served ${bytes.len().to_str()} bytes, not ${size.to_str()}")
		} else if actual != sha256 {
			Err("it served SHA-256 ${actual}, not ${sha256}")
		} else {
			Ok({})
		}
	}

	# The first bytes of `urls` that `accept` takes; the error says what each
	# one answered.
	served! :
		Str, List(Str), (List(U8) -> Try({}, Str)), Output.Mode => Try(List(U8), _)
	served! = |name, urls, accept, mode| {
		var $failures = []
		for url in urls {
			message = "downloading ${name} from ${url}"
			event = Output.event("note", message, [])
			Output.note!(mode, "kai: ${message}", event)?
			answer = match Store.get!(url, 1) {
				Ok(bytes) => accept(bytes).map_ok(|_| bytes)
				Err(why) => Err(why)
			}
			match answer {
				Ok(bytes) => return Ok(bytes)
				Err(why) => {
					$failures = $failures.append("${url}: ${why}")
				}
			}
		}
		failures = Str.join_with($failures, "; ")
		Err(StoreFailed("could not download ${name}: ".concat(failures)))
	}

	# One URL's body, asked three times when the transfer fails or the server
	# says to come back. basic-cli refuses a redirect away from HTTPS.
	get! : Str, U64 => Try(List(U8), Str)
	get! = |url, attempt| {
		request = Request.from_method(GET)
			.with_uri(url)
			.with_timeout(TimeoutMilliseconds(300_000))
		(again, why) = match Http.send!(request, { max_redirects: 5 }) {
			Ok(response) => {
				status = Response.status(response)
				if status >= 200 and status < 300 {
					return Ok(Response.body(response))
				}
				(Store.retryable(status), "HTTP ${status.to_str()}")
			}
			Err(HttpErr(InsecureRedirect)) => (Bool.False, "a redirect left HTTPS")
			Err(HttpErr(RedirectLimitExceeded(_))) => (Bool.False, "too many redirects")
			Err(HttpErr(_)) => (Bool.True, "no answer")
			Err(_) => (Bool.False, "not a URL")
		}
		if again and attempt < 3 {
			_ = Sleep.millis!(250 * attempt)
			Store.get!(url, attempt + 1)
		} else {
			Err(why)
		}
	}

	# Whether asking again could help: the server was busy or failed.
	retryable : U16 -> Bool
	retryable = |status| status == 408 or status == 429 or status >= 500

	# A file's SHA-256, read in bounded chunks.
	digest! : Str => Try(Str, _)
	digest! = |file| {
		reader = File.open_reader_with_capacity!(Workspace.path(file), 65536)?
		var $hasher = Crypto.SHA256.Hasher.empty()
		for! chunk in reader.chunks() {
			$hasher = $hasher.write(chunk?)
		}
		Ok($hasher.finish().to_hex())
	}

	# A fresh directory beside `file`, on one filesystem with it.
	beside! = |file| {
		directory = Workspace.path(Workspace.parent(file))
		directory.create_all!()?
		Env.create_temp_dir_in!(directory, ".tmp-")
	}

	# Write verified bytes under a fresh name, then rename them into place.
	keep! : Str, List(U8) => Try({}, _)
	keep! = |file, bytes| {
		temporary = Store.beside!(file)?
		staged = temporary.join("file")
		kept = match staged.write_bytes!(bytes) {
			Ok({}) => staged.rename!(Workspace.path(file))
			Err(err) => Err(err)
		}
		_ = temporary.delete_all!()
		kept
	}

	# Unpack a verified archive whole, since a program may need what lies
	# beside it, after listing it: a hard link out of the tree cannot be told
	# from a file afterwards. Another kai may place the same tree first.
	unpack! : Str, Str, Str => Try({}, _)
	unpack! = |artifact, tree, name| {
		names = Store.tool!("tar", ["-tf", artifact], "list ${name}")?
		long = Store.tool!("tar", ["-tvf", artifact], "list ${name}")?
		files = Store.refusal(names, long).map_err(
			|why| StoreFailed("the archive for ${name} is not unpacked: ${why}"),
		)?
		temporary = Store.beside!(tree)?
		staged = temporary.join("tree")
		staged.create_dir!()?
		into = staged.to_str()?
		moved = match Store.extract!(artifact, into, files, name) {
			Ok({}) => staged.rename!(Workspace.path(tree))
			Err(err) => Err(err)
		}
		_ = temporary.delete_all!()
		if Workspace.path(tree).is_dir!() ?? Bool.False {
			Ok({})
		} else {
			moved
		}
	}

	# Unpack an archive into `into` and make its files read-only; directories
	# stay writable, so that the tree can still be removed.
	extract! : Str, Str, List(Str), Str => Try({}, [StoreFailed(Str)])
	extract! = |artifact, into, files, name| {
		_ = Store.tool!("tar", ["-xf", artifact, "-C", into], "unpack ${name}")?
		for batch in files.chunks_of(256) {
			read_only = ["a-w", "--"].concat(batch.map(|file| "${into}/${file}"))
			_ = Store.tool!("chmod", read_only, "make ${name} read-only")?
		}
		Ok({})
	}

	tool! : Str, List(Str), Str => Try(Str, [StoreFailed(Str)])
	tool! = |program, args, purpose| {
		command = Cmd.new(OsStr.from_str(program)).args(args.map(OsStr.from_str))
		why = match command.run!() {
			Ok(ran) if ran.status == Exited(0) =>
				return Ok(Str.from_utf8_lossy(ran.stdout_bytes))
			Ok(ran) => Str.from_utf8_lossy(ran.stderr_bytes).trim()
			Err(_) => "it did not start"
		}
		Err(StoreFailed("could not ${purpose}: ".concat(why)))
	}

	# A name as an archive lists it, without `./` and a directory's last `/`.
	clean : Str -> Str
	clean = |name|
		Str.join_with(
			name.split_on("/").keep_if(|part| part != "" and part != "."),
			"/",
		)

	# Whether a link's target, taken from the link's directory, stays in the
	# tree.
	inside : Str, Str -> Bool
	inside = |from, target| {
		if target.is_empty() or target.starts_with("/") {
			return Bool.False
		}
		var $kept = Store.clean(from).split_on("/").keep_if(|part| part != "")
		for part in Store.clean(target).split_on("/") {
			if part == ".." {
				if $kept.is_empty() {
					return Bool.False
				}
				$kept = $kept.drop_last(1)
			} else if part != "" {
				$kept = $kept.append(part)
			}
		}
		Bool.True
	}

	# What is wrong with an archive, from its two listings, `tar -tf` and
	# `tar -tvf`, line for line: an absolute name, a `..` segment, a name that
	# is not plain text, a link leaving the tree, or anything other than a
	# file, a directory or a link. Otherwise, its regular files.
	refusal : Str, Str -> Try(List(Str), Str)
	refusal = |names_text, long_text| {
		lines = |text| text.split_on("\n").keep_if(|line| !line.is_empty())
		names = lines(names_text)
		long = lines(long_text)
		if names.len() != long.len() {
			return Err("its two listings disagree")
		}
		var $index = 0
		var $files = []
		for name in names {
			line = long.get($index) ?? ""
			Store.entry_refusal(name, line)?
			if line.starts_with("-") {
				$files = $files.append(Store.clean(name))
			}
			$index = $index + 1
		}
		Ok($files)
	}

	# What is wrong with one entry of an archive: its name and its `tar -tvf`
	# line.
	entry_refusal : Str, Str -> Try({}, Str)
	entry_refusal = |name, line| {
		plain = name.to_utf8().all(|b| b >= ' ' and b != 127)
		parent = Str.join_with(Store.clean(name).split_on("/").drop_last(1), "/")
		unreadable = "its listing of ${name} cannot be read"
		leaves = "it holds a link ${name} out of the tree"
		if name.starts_with("/") or !plain {
			return Err("it holds the name ${Str.inspect(name)}")
		}
		if name.split_on("/").contains("..") {
			return Err("it holds ${name}, which leaves the tree")
		}
		match line.to_utf8().first() {
			Ok('-') | Ok('d') =>
				if (line.ends_with(" ${name}")) Ok({}) else Err(unreadable)
			Ok('l') =>
				match line.split_on(" ${name} -> ") {
					[_, target] =>
						if (Store.inside(parent, target)) Ok({}) else Err(leaves)
					_ => Err(unreadable)
				}
			Ok('h') =>
				match line.split_on(" ${name} link to ") {
					[_, target] =>
						if Store.inside("", target) and !target.split_on("/").contains("..") {
							Ok({})
						} else {
							Err(leaves)
						}
					_ => Err(unreadable)
				}
			_ => Err("it holds ${name}, not a file, directory or link")
		}
	}
}

program : Plan.Program
program = {
	name: "tool",
	urls: ["https://example.com/tool"],
	sha256: "ab".repeat(32),
	size: 3,
	unpack: Archive("dir/tool"),
}

# Only a named program, by digest and size, over HTTPS, from inside its
# archive, is downloaded.
expect Store.check(program) == Ok({})
	and Store.check({ ..program, unpack: File }) == Ok({})
	and [
		{ ..program, name: "../tool" },
		{ ..program, urls: [] },
		{ ..program, urls: ["http://example.com/tool"] },
		{ ..program, urls: ["https://example.com/tool", "ftp://example.com/t"] },
		{ ..program, sha256: "AB".repeat(32) },
		{ ..program, sha256: "ab" },
		{ ..program, size: 0 },
		{ ..program, unpack: Archive("/bin/tool") },
		{ ..program, unpack: Archive("dir/../../tool") },
	].all(|bad| Store.check(bad).is_err())

# Bytes of another length or digest are refused.
expect {
	bytes = "abc".to_utf8()
	sha256 = Crypto.SHA256.hash(bytes).to_hex()
	pinned = { ..program, sha256 }
	Store.verified(pinned, bytes) == Ok({})
		and Store.verified({ ..pinned, size: 4 }, bytes).is_err()
		and Store.verified({ ..pinned, sha256: "ab".repeat(32) }, bytes).is_err()
}

# A busy or failing server is asked again; a refusal is not.
expect [408, 429, 500, 503].all(Store.retryable)
	and ![400, 403, 404, 410].any(Store.retryable)

entry = |kind, name, rest|
	"${kind}rw-r--r-- 0 u g 1 2026-01-01 00:00 ${name}${rest}"

# An archive of plain files, directories and links inside it is unpacked;
# anything else refuses the whole archive.
expect {
	listing = |rows|
		Store.refusal(
			Str.join_with(rows.map(|(_, name, _)| name), "\n"),
			Str.join_with(rows.map(|(kind, name, rest)| entry(kind, name, rest)), "\n"),
		)
	file = ("-", "a/b", "")
	good = [
		("d", "./a/", ""),
		file,
		("l", "a/c", " -> b"),
		("l", "a/d", " -> ../a/b"),
		("h", "a/e", " link to a/b"),
	]
	bad = [
		("-", "/etc/passwd", ""),
		("-", "a/../../b", ""),
		("-", "a/\u(1b)b", ""),
		("l", "a/c", " -> /etc/passwd"),
		("l", "a/c", " -> ../../b"),
		("h", "a/c", " link to /etc/passwd"),
		("h", "a/c", " link to ../b"),
		("c", "a/dev", ""),
		("p", "a/fifo", ""),
	]
	listing(good) == Ok(["a/b"])
		and bad.all(|row| listing([file, row]).is_err())
		and Store.refusal("a\nb", "-rw a").is_err()
}
