# What a Kai project declares and locks, as the inputs an SBOM inventory
# must dispose of: std's model of the settings and the lock's pins, under
# the names Blueprint's profile gives them, so a composition reviewed for
# a Blueprint project fits the same project on Kai.
import pf.LockJson
import pf.Plan
import std.StdModel exposing [Model]
import Profile

Inputs := [].{

	## The project's inputs. Each download is a `program` per system, except
	## one URL and SHA-256 for every system that no environment puts on
	## PATH (a FetchAll), which is a `source` file; RocPackages bundles are
	## Roc packages and build sources, as Blueprint's RocPackages are; the
	## lock's Nix package sources, overlays and flake inputs are sources.
	## A download the lock should pin and does not is `missing_direct_lock`,
	## and one it pins for another URL `stale_lock`.
	from : Model, [Absent, Present(Str)] -> Try(Profile.Inputs, Plan.Failure)
	from = |declared, lock| {
		model = StdModel.validate(declared).map_err(Plan.fail)?
		entries = match lock {
			Present(text) => Inputs.report(text)?
			Absent => []
		}
		bundles = unique(model.environments.join_map(|e| e.roc_packages))
		hashes = bundles.map_try(bundle_hash).map_err(Plan.fail)?
		bundle_fetches = hashes.map(|hash| "roc-${hash}")
		tools = model.environments.join_map(environment_tools)
		fetch_names = model.fetches.map(|f| f.name)
		downloaded = tools.keep_if(|t| fetch_names.contains(t.tool.source))
			.map(|t| t.tool.source)
		packaged = tools.keep_if(|t| !fetch_names.contains(t.tool.source))
		guix = model.sources.keep_if(
			|s|
				match s.provider {
					GuixPackages(_) => Bool.True
					_ => Bool.False
				},
		)
		match guix.first() {
			Ok(source) =>
				return Err(
					Plan.fail(
						"kai sbom does not inventory Guix package sources yet: ${source.name}",
					),
				)
			Err(_) => {}
		}
		# The package sources tools come from, and the overlays and flake
		# inputs, each by the Nix pin the lock holds for it.
		declared_sources = unique(
			packaged.map(|t| t.tool.source).concat(model.inputs.map(|i| i.name)),
		)
		kinds = ["package_source", "overlay", "flake_input"]
		nix_sources = declared_sources.map_try(
			|name| {
				pinned = |e| e.section == "nix" and
					e.name == name and
						kinds.contains(e.kind)
				entry = entries.find_first(pinned).map_err(
					|_| failure(
						"missing_lock",
						"the lock has no Nix pin for ${name}",
						"kai update",
					),
				)?
				Ok({
					name,
					provider: "nix",
					ref: entry.url,
					rev: entry.revision,
					digest: entry.hash,
				})
			},
		)?
		pins = entries.keep_if(|e| e.section == "direct")
		var $sources = []
		var $fetched = []
		for fetch in model.fetches {
			if !bundle_fetches.contains(fetch.name) {
				files = fetch.files.map_try(|file| digest(fetch.name, file, pins))?
				one = |values| unique(values).len() == 1
				single = !files.is_empty()
					and one(files.map(|(f, _)| f.url))
					and one(files.map(|(_, sha256)| sha256))
					and files.all(|(f, _)| f.mirrors.is_empty() and f.unpack == File)
				match files {
					[(first, sha256), ..] if single and !downloaded.contains(fetch.name) => {
						$sources = $sources.append({
							name: fetch.name,
							provider: "file",
							ref: first.url,
							rev: "",
							digest: "sha256:${sha256}",
						})
					}
					_ => {
						$fetched = $fetched.concat(
							files.map(
								|(file, sha256)| {
									name: fetch.name,
									system: file.system,
									urls: [file.url].concat(file.mirrors),
									sha256,
								},
							),
						)
					}
				}
			}
		}
		Ok({
			systems: model.systems,
			sources: $sources.concat(nix_sources),
			fetched: $fetched,
			tools: unique_tools(
				packaged.map(
					|t| { name: "${t.tool.source}#${t.tool.name}", systems: t.systems },
				),
			),
			roc_packages: hashes,
			build_sources: bundle_fetches.concat(model.build_sources.map(|s| s.name)),
			others: model.cargo_vendors.map(|v| "cargo-vendor:${v.name}"),
			tasks: model.tasks.map(|t| t.name),
			builds: model.builds.map(|b| b.name),
		})
	}

	## The lock's pins as `kai lock` reports them.
	Entry : {
		section : Str,
		kind : Str,
		name : Str,
		url : Str,
		revision : Str,
		hash : Str,
		system : Str,
	}

	## The entries of the lock report of `text`, or `invalid_lock`.
	report : Str -> Try(List(Entry), Plan.Failure)
	report = |text| {
		invalid = |why| failure(
			"invalid_lock",
			"cannot read the lock: ${why}",
			"kai update",
		)
		json = StdModel.lock_report(text).map_err(invalid)?
		tree = LockJson.decode(json).map_err(invalid)?
		listed = LockJson.array(LockJson.field(tree, "inputs").map_err(invalid)?)
			.map_err(invalid)?
		listed.map_try(
			|entry| {
				value = |name| {
					found = LockJson.field(entry, name).map_err(invalid)?
					match found {
						String(s) => Ok(s)
						_ => Ok("")
					}
				}
				hash = match LockJson.field(entry, "hash") {
					Ok(Object(_) as object) => {
						found = LockJson.field(object, "value").map_err(invalid)?
						LockJson.string(found).map_err(invalid)?
					}
					_ => ""
				}
				Ok({
					section: value("section")?,
					kind: value("kind")?,
					name: value("name")?,
					url: value("url")?,
					revision: value("revision")?,
					hash,
					system: value("system")?,
				})
			},
		)
	}

	## The hex SHA-256 of a `sha256-…` SRI hash.
	sri_hex : Str -> Try(Str, [InvalidSri])
	sri_hex = |sri| {
		alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
			.to_utf8()
		encoded = sri.drop_prefix("sha256-").drop_suffix("=").to_utf8()
		if !sri.starts_with("sha256-") or encoded.len() != 43 {
			return Err(InvalidSri)
		}
		values = encoded.map_try(
			|char| alphabet.find_first_index(|a| a == char).map_err(|_| InvalidSri),
		)?
		padded = values.append(0).map(|v| v.to_u64())
		var $bytes = []
		var $i = 0
		while $i < padded.len() {
			at = |k| padded.get($i + k) ?? 0
			n = at(0) * 262144 + at(1) * 4096 + at(2) * 64 + at(3)
			$bytes = $bytes.concat([n // 65536, (n // 256) % 256, n % 256])
			$i = $i + 4
		}
		digits = "0123456789abcdef".to_utf8()
		hex = $bytes.take_first(32).join_map(
			|b| [
				digits.get((b // 16).to_u64()) ?? '0',
				digits.get((b % 16).to_u64()) ?? '0',
			],
		)
		Ok(Str.from_utf8_lossy(hex))
	}
}

## A Plan.Failure with a code and the command that fixes it.
failure : Str, Str, Str -> Plan.Failure
failure = |code, message, hint| { code, message, hint, suggestions: [] }

## The SHA-256 a file is pinned by: its own `sha256-` hash, or the lock's
## direct pin for `<fetch>/<system>`.
digest :
	Str,
	Model.FetchFile,
	List(Inputs.Entry) -> Try(
		(Model.FetchFile, Str),
		Plan.Failure,
	)
digest = |fetch, file, pins| {
	key = "${fetch}/${file.system}"
	if !file.hash.is_empty() {
		hex = Inputs.sri_hex(file.hash)
			.map_err(|_| Plan.fail("invalid sha256 for ${key}"))?
		return Ok((file, hex))
	}
	hint = "kai --backend direct update"
	pin = pins.find_first(|p| p.name == key).map_err(
		|_| failure(
			"missing_direct_lock",
			"the lock has no direct pin for ${key}",
			hint,
		),
	)?
	if pin.url != file.url {
		why = "the direct pin for ${key} does not match its Fetch"
		return Err(failure("stale_lock", why, hint))
	}
	Ok((file, pin.hash))
}

## The hash a RocPackages URL ends in.
bundle_hash : Str -> Try(Str, Str)
bundle_hash = |url| {
	hash = (url.split_on("/").last() ?? "").drop_suffix(".tar.zst")
	if url.starts_with("https://") and
		url.ends_with("/${hash}.tar.zst") and
			!hash.is_empty() {
		Ok(hash)
	} else {
		Err("RocPackages needs https://.../<hash>.tar.zst: ${url}")
	}
}

## An environment's tools, each with the systems it is on ([] for all).
environment_tools :
	Model.Environment -> List({ tool : Model.Tool, systems : List(Str) })
environment_tools = |environment| {
	everywhere = StdModel.environment_tools({ ..environment, on_systems: [] })
	# One OnSystems' tools, its PackageEnv's included.
	only = |on|
		StdModel.environment_tools(
			{ ..environment, tools: [], aliases: [], package_env: [], on_systems: [on] },
		)
	everywhere.map(|tool| { tool, systems: [] })
		.concat(
			environment.on_systems.join_map(
				|on| only(on).map(|tool| { tool, systems: on.systems }),
			),
		)
}

unique : List(Str) -> List(Str)
unique = |values|
	values.fold(
		[],
		|all, value| if (all.contains(value)) all else all.append(value),
	)

## Each tool once, on the systems any of its entries names, or on all.
unique_tools : List(Profile.Tool) -> List(Profile.Tool)
unique_tools = |tools|
	tools.fold(
		[],
		|all, tool|
			match all.find_first_index(|t| t.name == tool.name) {
				Ok(index) => {
					earlier = all.get(index) ?? tool
					systems = if earlier.systems.is_empty() or tool.systems.is_empty() {
						[]
					} else {
						unique(earlier.systems.concat(tool.systems))
					}
					all.set(index, { ..earlier, systems }) ?? all
				}
				Err(_) => all.append(tool)
			},
	)

# An SRI SHA-256 decodes to the hex digits of the same bytes.
expect
	Inputs.sri_hex("sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")
		== Ok("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
		and Inputs.sri_hex("e3b0").is_err()
