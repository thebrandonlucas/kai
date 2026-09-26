# Versioned authoritative pins. Native lock graphs are decoded, checked and
# rebased as data. Ordinary plans never resolve or change authoritative pins.
import api.Layout
import ir.Ir
import ir.Project
import ir.Plan
import LockJson

Locks := { identity : LockJson, graph : LockJson }.{
	is_eq : _

	Input : { name : Str, ref : Str, kind : Str, flake : Bool }
	default_nixpkgs : Str
	default_nixpkgs = "github:NixOS/nixpkgs/nixos-unstable"

	## All supported declarations have stable, user-named root inputs. Foreign
	## package providers stay outside Nix, not silently rewritten as nixpkgs.
	inputs : Ir -> Try(List(Input), Str)
	inputs = |ir| {
		var $inputs = []
		for source in ir.sources {
			match source.provider {
				GuixPackages(_) => {}
				Auto => {
					$inputs = $inputs.append({
						name: source.name,
						ref: default_nixpkgs,
						kind: "auto",
						flake: True,
					})
				}
				NixPackages(ref) => {
					$inputs = $inputs.append({
						name: source.name,
						ref: normalize_ref(ref)?,
						kind: "packages",
						flake: True,
					})
				}
			}
		}
		for input in ir.inputs {
			$inputs = $inputs.append({
				name: input.name,
				ref: normalize_ref(input.url)?,
				flake: True,
				kind: if input.kind == Overlay "overlay" else "flake",
			})
		}
		for source in ir.build_sources {
			$inputs = $inputs.append({
				name: source.name,
				ref: normalize_ref(source.ref)?,
				kind: "source",
				flake: False,
			})
		}
		for input in $inputs {
			_ = original(input.ref)?
		}
		Ok($inputs)
	}

	## B2 local references are normalized project-relative subtrees. Local Git,
	## absolute paths and query escapes are rejected instead of losing identity.
	normalize_ref : Str -> Try(Str, Str)
	normalize_ref = |ref| {
		if ref.starts_with("path:") {
			path = ref.drop_prefix("path:").drop_prefix("./")
			if !Project.valid_output(path) or path.contains("?")
				or path.contains("#") or path.contains("%") {
				return Err("local input must be a project-relative subtree: ${ref}")
			}
			Ok("path:${path}")
		} else if ref.contains("file:") or ref.starts_with("/")
			or ref.starts_with(".") {
			Err("local input must use path:<project-relative subtree>: ${ref}")
		} else Ok(ref)
	}

	local_path : Input -> Str
	local_path = |input| input.ref.drop_prefix("path:")

	input_url : Input, Layout -> Str
	input_url = |input, layout| if input.ref.starts_with("path:") {
		"path:${layout.project_root}/${local_path(input)}"
	} else input.ref

	identity_for : Ir -> Try(LockJson, Str)
	identity_for = |ir| {
		declared = inputs(ir)?
		Ok(
			LockJson.Object([
				{
					name: "inputs",
					value: LockJson.Object(
						declared.map(
							|input| {
								name: input.name,
								value: LockJson.Object([
									{ name: "ref", value: LockJson.String(input.ref) },
									{ name: "kind", value: LockJson.String(input.kind) },
									{ name: "flake", value: LockJson.Boolean(input.flake) },
								]),
							},
						),
					),
				},
				{
					name: "overlays",
					value: LockJson.Object(
						ir.environments.map(
							|env| {
								name: env.name,
								value: LockJson.Array(env.overlays.map(|name| LockJson.String(name))),
							},
						),
					),
				},
			]),
		)
	}

	decode : Str -> Try(Locks, Str)
	decode = |text| {
		envelope = LockJson.decode(text)?
		if LockJson.field(envelope, "version")? != LockJson.Number("1") {
			return Err("unsupported Kai lock version; run kai update")
		}
		identity = LockJson.field(envelope, "identity")?
		graph = LockJson.field(envelope, "nix")?
		validate_identity(identity)?
		validate_graph(graph)?
		validate_binding(identity, graph)?
		Ok(Locks.{ identity, graph })
	}

	encode : Locks -> Str
	encode = |locks| LockJson.encode(
		LockJson.Object([
			{ name: "version", value: LockJson.Number("1") },
			{ name: "identity", value: locks.identity },
			{ name: "nix", value: locks.graph },
		]),
	).concat("\n")

	## Explicit update alone may supply fresh Nix observations. Every local node
	## is tied to a declared relative identity and retains its NAR content hash.
	from_nix : Ir, Layout, Str -> Try(Locks, Str)
	from_nix = |ir, layout, text| {
		Layout.validate(layout)?
		project = Project.validate(ir)?
		identity = identity_for(project)?
		graph = LockJson.decode(text)?
		validate_graph(graph)?
		declared = inputs(project)?
		root = root_inputs(graph)?
		nodes = LockJson.object(LockJson.field(graph, "nodes")?)?
		var $nodes = []
		for node in nodes {
			var $value = node.value
			for input in declared.keep_if(|i| i.ref.starts_with("path:")) {
				id = LockJson.string(LockJson.field(root, input.name)?)?
				if node.name == id {
					for field in ["original", "locked"] {
						attrs = LockJson.field($value, field)?
						path = LockJson.string(LockJson.field(attrs, "path")?)?
						expected = "${layout.project_root}/${local_path(input)}"
						if path != expected and path != local_path(input) {
							return Err("Nix local input path does not match ${input.name}")
						}
						$value = LockJson.set(
							$value,
							field,
							LockJson.set(attrs, "path", LockJson.String(local_path(input)))?,
						)?
					}
				}
			}
			$nodes = $nodes.append({ name: node.name, value: $value })
		}
		normalized = LockJson.set(graph, "nodes", LockJson.Object($nodes))?
		validate_binding(identity, normalized)?
		Ok(Locks.{ identity, graph: normalized })
	}

	## Matching ignores object/declaration order, but never array/overlay order.
	## Revalidate even nominal values constructed directly by library consumers.
	derive : Locks,
	Ir,
	Layout -> Try(
		{ contents : Str, operations : List(Plan.Operation) },
		Str,
	)
	derive = |locks, ir, layout| {
		Layout.validate(layout)?
		project = Project.validate(ir)?
		validate_identity(locks.identity)?
		validate_graph(locks.graph)?
		validate_binding(locks.identity, locks.graph)?
		if !equivalent(locks.identity, identity_for(project)?) {
			return Err(
				"lock input or ordered-overlay identity changed; "
					.concat("run kai update"),
			)
		}
		root = root_inputs(locks.graph)?
		nodes = LockJson.object(LockJson.field(locks.graph, "nodes")?)?
		declared = inputs(project)?
		var $nodes = []
		var $operations = []
		for node in nodes {
			var $value = node.value
			for input in declared.keep_if(|i| i.ref.starts_with("path:")) {
				id = LockJson.string(LockJson.field(root, input.name)?)?
				if node.name == id {
					path = "${layout.project_root}/${local_path(input)}"
					locked = LockJson.field($value, "locked")?
					nar_hash = LockJson.string(LockJson.field(locked, "narHash")?)?
					operation = VerifyLocal({ path, nar_hash })
					if !$operations.contains(operation) {
						$operations = $operations.append(operation)
					}
					for field in ["original", "locked"] {
						attrs = LockJson.field($value, field)?
						$value = LockJson.set(
							$value,
							field,
							LockJson.set(attrs, "path", LockJson.String(path))?,
						)?
					}
				}
			}
			$nodes = $nodes.append({ name: node.name, value: $value })
		}
		graph = LockJson.set(locks.graph, "nodes", LockJson.Object($nodes))?
		Ok({ contents: LockJson.encode(graph).concat("\n"), operations: $operations })
	}

	validate_identity : LockJson -> Try({}, Str)
	validate_identity = |identity| {
		inputs_ = LockJson.object(LockJson.field(identity, "inputs")?)?
		for input in inputs_ {
			if !Project.valid_name(input.name) {
				return Err("invalid lock input name")
			}
			ref = LockJson.string(LockJson.field(input.value, "ref")?)?
			if normalize_ref(ref)? != ref {
				return Err("noncanonical lock reference")
			}
			_ = original(ref)?
			kind = LockJson.string(LockJson.field(input.value, "kind")?)?
			if !["auto", "packages", "overlay", "flake", "source"].contains(kind) {
				return Err("unsupported lock input kind")
			}
			if LockJson.field(
				input.value,
				"flake",
			)? != LockJson.Boolean(kind != "source") {
				return Err("lock input flake intent mismatch")
			}
		}
		overlays = LockJson.object(LockJson.field(identity, "overlays")?)?
		for env in overlays {
			if !Project.valid_name(env.name) {
				return Err("invalid lock environment")
			}
			var $seen = []
			for item in LockJson.array(env.value)? {
				name = LockJson.string(item)?
				input = inputs_.find_first(|i| i.name == name)
					.map_err(|_| "unknown lock overlay: ${name}")?
				if LockJson.field(input.value, "kind")? != LockJson.String("overlay")
					or $seen.contains(name) {
					return Err("invalid ordered overlay identity")
				}
				$seen = $seen.append(name)
			}
		}
		Ok({})
	}

	root_inputs : LockJson -> Try(LockJson, Str)
	root_inputs = |graph| {
		root = LockJson.string(LockJson.field(graph, "root")?)?
		node = LockJson.field(LockJson.field(graph, "nodes")?, root)?
		Ok(LockJson.field(node, "inputs") ?? LockJson.Object([]))
	}

	## Validate native v7 shape, immutable fetch identities and every graph edge.
	## Follows share a memo and total visit budget across the complete graph.
	validate_graph : LockJson -> Try({}, Str)
	validate_graph = |graph| {
		if LockJson.field(graph, "version")? != LockJson.Number("7") {
			return Err("unsupported Nix lock version")
		}
		root = LockJson.string(LockJson.field(graph, "root")?)?
		nodes_json = LockJson.field(graph, "nodes")?
		nodes = LockJson.object(nodes_json)?
		if nodes.len() > 4096 or !nodes.any(|n| n.name == root) {
			return Err("invalid Nix lock root or too many nodes")
		}
		var $traversal = { remaining: 16384, resolved: [] }
		for node in nodes {
			if !Project.valid_name(node.name) {
				return Err("invalid Nix lock node name")
			}
			_ = LockJson.object(node.value)?
			if node.name == root {
				for field in LockJson.object(node.value)? {
					if field.name != "inputs" {
						return Err("unexpected Nix root node attribute")
					}
				}
			} else {
				locked = LockJson.field(node.value, "locked")?
				original_ = LockJson.field(node.value, "original")?
				check_fetch(locked, True)?
				check_fetch(original_, False)?
				original_type = LockJson.field(original_, "type")?
				if original_type != LockJson.String("indirect")
					and LockJson.field(locked, "type")? != original_type {
					return Err("Nix locked/original fetch types differ")
				}
				# Nix supplies these defaults even when original omits host.
				# Compare effective origins, not only explicitly declared fields.
				default_host = match original_type {
					LockJson.String("github") => "github.com"
					LockJson.String("gitlab") => "gitlab.com"
					LockJson.String("sourcehut") => "git.sr.ht"
					_ => ""
				}
				if !default_host.is_empty() {
					fallback = LockJson.String(default_host)
					if (LockJson.field(original_, "host") ?? fallback)
						!= (LockJson.field(locked, "host") ?? fallback) {
						return Err("locked fetch host differs from original")
					}
				}
				fields = ["owner", "repo", "url", "dir", "rev", "narHash"]
					.concat(if default_host.is_empty() ["host"] else [])
				for field in fields {
					match LockJson.field(original_, field) {
						Ok(expected) => {
							if LockJson.field(locked, field)? != expected {
								return Err("locked fetch identity differs from original")
							}
						}
						Err(_) => {}
					}
				}
				match LockJson.field(node.value, "flake") {
					Ok(LockJson.Boolean(_)) => {}
					Err(_) => {}
					_ => return Err("invalid Nix flake marker")
				}
			}
			edges = LockJson.field(node.value, "inputs") ?? LockJson.Object([])
			for edge in LockJson.object(edges)? {
				if !Project.valid_name(edge.name) {
					return Err("invalid Nix input edge")
				}
				resolved = resolve_edge(
					graph,
					(node.name, edge.name),
					$traversal,
					[],
				)?
				$traversal = resolved.traversal
			}
		}
		Ok({})
	}

	EdgeKey : (Str, Str)
	Traversal : {
		remaining : U64,
		resolved : List({ key : EdgeKey, name : Str }),
	}

	## Cache completed edges by owner and input name, never partial results.
	## Charge every visit, including memo hits and each follows path segment;
	## neither sibling paths nor the outer graph loop may replenish the budget.
	resolve_edge : LockJson,
	EdgeKey,
	Traversal,
	List(EdgeKey) -> Try(
		{ name : Str, traversal : Traversal },
		Str,
	)
	resolve_edge = |graph, key, traversal, active| {
		if traversal.remaining == 0 {
			return Err("Nix input traversal exceeds 16384 edge visits")
		}
		var $traversal = { ..traversal, remaining: traversal.remaining - 1 }
		if active.contains(key) {
			return Err("Nix follows cycle")
		}
		if active.len() >= 128 {
			return Err("Nix follows depth exceeds 128")
		}
		match $traversal.resolved.find_first(|entry| entry.key == key) {
			Ok(entry) => return Ok({ name: entry.name, traversal: $traversal })
			Err(_) => {}
		}
		nodes = LockJson.field(graph, "nodes")?
		(owner, input) = key
		node = LockJson.field(nodes, owner)?
		edge = LockJson.field(LockJson.field(node, "inputs")?, input)?
		name = match edge {
			LockJson.String(target) => {
				_ = LockJson.field(nodes, target)?
				target
			}
			LockJson.Array(path) => {
				var $name = LockJson.string(LockJson.field(graph, "root")?)?
				for segment in path {
					resolved = resolve_edge(
						graph,
						($name, LockJson.string(segment)?),
						$traversal,
						active.append(key),
					)?
					$name = resolved.name
					$traversal = resolved.traversal
				}
				$name
			}
			_ => return Err("invalid Nix input edge")
		}
		Ok({
			name,
			traversal: {
				..$traversal,
				resolved: $traversal.resolved.append({ key, name }),
			},
		})
	}

	valid_hash : Str -> Bool
	valid_hash = |hash| {
		bytes = hash.drop_prefix("sha256-").to_utf8()
		hash.starts_with("sha256-") and bytes.len() == 44
			and bytes.last() == Ok('=')
				and "AEIMQUYcgkosw048".to_utf8().contains(bytes.get(42) ?? 0)
					and bytes.take_first(43).all(
						|b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')
							or (b >= '0' and b <= '9') or b == '+' or b == '/',
					)
	}

	valid_rev : Str -> Bool
	valid_rev = |rev| (rev.to_utf8().len() == 40 or rev.to_utf8().len() == 64)
		and rev.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))

	check_fetch : LockJson, Bool -> Try({}, Str)
	check_fetch = |attrs, locked| {
		kind = LockJson.string(LockJson.field(attrs, "type")?)?
		for field in LockJson.object(attrs)? {
			if (field.name == "path" and kind != "path")
				or (field.name == "url"
					and !["git", "tarball", "file"].contains(kind)) {
				return Err("fetch attribute does not belong to its fetch type")
			}
			strings = [
				"type",
				"id",
				"owner",
				"repo",
				"rev",
				"ref",
				"host",
				"url",
				"dir",
				"path",
				"narHash",
			]
			numbers = ["lastModified", "revCount"]
			booleans = ["submodules", "shallow", "allRefs", "lfs"]
			if strings.contains(field.name) {
				text = LockJson.string(field.value)?
				if field.name == "dir" and !Project.valid_output(text) {
					return Err("invalid Nix source subdirectory")
				}
			} else if numbers.contains(field.name) {
				match field.value {
					LockJson.Number(text) => {
						_ = U64.from_str(text)
							.map_err(|_| "invalid numeric fetch attribute")?
					}
					_ => return Err("invalid numeric fetch attribute")
				}
			} else if booleans.contains(field.name) {
				match field.value {
					LockJson.Boolean(_) => {}
					_ => return Err("invalid boolean fetch attribute")
				}
			} else return Err("unsupported Nix fetch attribute: ${field.name}")
			match field.value {
				LockJson.String(text) => if text.to_utf8().any(|b| b < 32 or b == 127) {
					return Err("control byte in Nix fetch identity")
				}
				LockJson.Number(_) => {}
				LockJson.Boolean(_) => {}
				_ => return Err("invalid Nix fetch attribute")
			}
		}
		if ![
			"github",
			"gitlab",
			"sourcehut",
			"git",
			"tarball",
			"file",
			"path",
			"indirect",
		].contains(kind) {
			return Err("unsupported Nix fetch type: ${kind}")
		}
		if kind == "indirect" {
			if locked {
				return Err("unresolved indirect Nix lock node")
			}
			id = LockJson.string(LockJson.field(attrs, "id")?)?
			if !Project.valid_name(id) {
				return Err("invalid Nix registry id")
			}
		}
		if locked and !valid_hash(
			LockJson.string(
				LockJson.field(
					attrs,
					"narHash",
				)?,
			)?,
		) {
			return Err("missing or invalid locked NAR hash")
		}
		if ["github", "gitlab", "sourcehut"].contains(kind) {
			for key in ["owner", "repo"] {
				if LockJson.string(LockJson.field(attrs, key)?)?.is_empty() {
					return Err("empty Nix fetch identity")
				}
			}
		}
		if ["git", "tarball", "file"].contains(kind) {
			url = LockJson.string(LockJson.field(attrs, "url")?)?
			if !remote_url(kind, url) {
				return Err("unsupported or local Nix fetch URL")
			}
		}
		if kind == "path" {
			path = LockJson.string(LockJson.field(attrs, "path")?)?
			if !Project.valid_output(path.drop_prefix("/")) {
				return Err("invalid local Nix path")
			}
		}
		if locked and ["github", "gitlab", "sourcehut", "git"].contains(kind)
			and !valid_rev(LockJson.string(LockJson.field(attrs, "rev")?)?) {
			return Err("missing or invalid immutable Nix revision")
		}
		Ok({})
	}

	## Bind the complete root input set to original declarations and flake intent.
	## Only direct declared path inputs are permitted; transitive host paths
	## cannot leak into a relocatable authority or bypass VerifyLocal.
	validate_binding : LockJson, LockJson -> Try({}, Str)
	validate_binding = |identity, graph| {
		inputs_ = LockJson.object(LockJson.field(identity, "inputs")?)?
		root = root_inputs(graph)?
		if LockJson.object(root)?.len() != inputs_.len() {
			return Err("Nix root input set does not match lock identity")
		}
		nodes = LockJson.field(graph, "nodes")?
		var $local_nodes = []
		for input in inputs_ {
			id = LockJson.string(LockJson.field(root, input.name)?)?
			node = LockJson.field(nodes, id)?
			ref = LockJson.string(LockJson.field(input.value, "ref")?)?
			expected = original(ref)?
			if !equivalent(expected, LockJson.field(node, "original")?) {
				return Err("Nix original reference does not match input ${input.name}")
			}
			flake = LockJson.field(node, "flake") ?? LockJson.Boolean(True)
			if flake != LockJson.field(input.value, "flake")? {
				return Err("Nix flake intent does not match input ${input.name}")
			}
			if ref.starts_with("path:") {
				path = LockJson.field(LockJson.field(node, "locked")?, "path")?
				if path != LockJson.String(ref.drop_prefix("path:")) {
					return Err("nonrelocatable locked local input ${input.name}")
				}
				$local_nodes = $local_nodes.append(id)
			}
		}
		root_name = LockJson.string(LockJson.field(graph, "root")?)?
		for node in LockJson.object(nodes)? {
			if node.name != root_name {
				locked = LockJson.field(node.value, "locked")?
				if LockJson.field(locked, "type")? == LockJson.String("path")
					and !$local_nodes.contains(node.name) {
					return Err("transitive local Nix inputs are unsupported")
				}
			}
		}
		Ok({})
	}

	## SSH belongs to Git transport, not HTTP file/tarball fetching.
	remote_url : Str, Str -> Bool
	remote_url = |kind, url| url.starts_with("https://")
		or url.starts_with("http://")
			or (kind == "git" and url.starts_with("ssh://"))

	## Decode the supported reference syntax into Nix original attributes.
	## Registry refs retain their original id but must lock to immutable fetches.
	original : Str -> Try(LockJson, Str)
	original = |ref| {
		if ref.starts_with("path:") {
			return Ok(
				LockJson.Object([
					{ name: "type", value: LockJson.String("path") },
					{ name: "path", value: LockJson.String(ref.drop_prefix("path:")) },
				]),
			)
		}
		parts = ref.split_on("?")
		base = parts.first() ?? ""
		var $attrs = []
		if base.starts_with("flake:") {
			segments = base.drop_prefix("flake:").split_on("/")
			id = segments.first() ?? ""
			if !Project.valid_name(id) or segments.any(Str.is_empty) {
				return Err("invalid registry reference: ${ref}")
			}
			$attrs = [
				{ name: "type", value: LockJson.String("indirect") },
				{ name: "id", value: LockJson.String(id) },
			]
			if segments.len() > 1 {
				suffix = Str.join_with(segments.drop_first(1), "/")
				$attrs = $attrs.append({
					name: if valid_rev(suffix) "rev" else "ref",
					value: LockJson.String(suffix),
				})
			}
		} else if ["github:", "gitlab:", "sourcehut:"].any(
			|p| base.starts_with(p),
		) {
			kind = base.split_on(":").first() ?? ""
			segments = base.drop_prefix("${kind}:").split_on("/")
			if segments.len() < 2 or segments.any(Str.is_empty) {
				return Err("invalid hosted Nix reference: ${ref}")
			}
			$attrs = [
				{ name: "type", value: LockJson.String(kind) },
				{ name: "owner", value: LockJson.String(segments.get(0) ?? "") },
				{ name: "repo", value: LockJson.String(segments.get(1) ?? "") },
			]
			if segments.len() > 2 {
				suffix = Str.join_with(segments.drop_first(2), "/")
				$attrs = $attrs.append({
					name: if valid_rev(suffix) "rev" else "ref",
					value: LockJson.String(suffix),
				})
			}
		} else {
			(kind, url) = if base.starts_with("git+") {
				("git", base.drop_prefix("git+"))
			} else ("tarball", base.drop_prefix("tarball+"))
			if !remote_url(kind, url) {
				return Err(
					"unsupported Nix reference: ${ref}; "
						.concat("use hosted, remote Git/tarball or path inputs"),
				)
			}
			$attrs = [
				{ name: "type", value: LockJson.String(kind) },
				{ name: "url", value: LockJson.String(url) },
			]
		}
		if parts.len() > 2 {
			return Err("invalid Nix reference query")
		}
		if parts.len() == 2 {
			for option in (parts.get(1) ?? "").split_on("&") {
				match option.split_on("=") {
					[name, value] => {
						if !["ref", "rev", "dir"].contains(name)
							or value.is_empty() or value.contains("%")
								or $attrs.any(|a| a.name == name) {
							return Err("unsupported or duplicate Nix reference option: ${name}")
						}
						if name == "dir" and !Project.valid_output(value) {
							return Err("invalid Nix source subdirectory")
						}
						$attrs = $attrs.append({ name, value: LockJson.String(value) })
					}
					_ => return Err("invalid Nix reference query")
				}
			}
		}
		Ok(LockJson.Object($attrs))
	}

	equivalent : LockJson, LockJson -> Bool
	equivalent = |a, b| match (a, b) {
		(LockJson.Object(left), LockJson.Object(right)) => left.len() == right.len()
			and left.all(
				|field| match right.find_first(|r| r.name == field.name) {
					Ok(other) => equivalent(field.value, other.value)
					Err(_) => False
				},
			)
		(LockJson.Array(left), LockJson.Array(right)) => {
			var $index = 0
			var $same = left.len() == right.len()
			for value in left {
				$same = $same and match right.get($index) {
					Ok(other) => equivalent(value, other)
					Err(_) => False
				}
				$index = $index + 1
			}
			$same
		}
		_ => a == b
	}
}

import TestData
import "tests/local.nix-lock.json" as native_fixture : Str

locked_fixture : Try(Locks, Str)
locked_fixture = Locks.from_nix(
	TestData.project(TestData.data),
	TestData.layout,
	native_fixture,
)

# Explicitly resolved native pins become a decoded, round-trippable authority.
expect match locked_fixture {
	Ok(locks) => Locks.decode(Locks.encode(locks)) == Ok(locks)
	Err(_) => False
}

# No checkout, workspace or generated-root absolute path enters authority.
expect match locked_fixture {
	Ok(locks) => {
		text = Locks.encode(locks)
		!text.contains("/project") and !text.contains("/generated")
			and !text.contains("/work") and text.contains("path:assets")
	}
	Err(_) => False
}

# Relocation changes derivative paths only, preserving every authoritative pin.
expect match locked_fixture {
	Ok(locks) => {
		project = Project.validate(TestData.project(TestData.data)) ?? Ir.empty("x")
		layout = Layout.{
			project_root: "/moved",
			workspace: "/elsewhere/work",
			generated_root: "/elsewhere/nix",
			lock_path: "/moved/custom.lock",
		}
		match Locks.derive(locks, project, layout) {
			Ok(derived) => derived.contents.contains("/moved/assets")
				and !derived.contents.contains("/project")
					and derived.operations == [
						VerifyLocal({
							path: "/moved/assets",
							nar_hash: "sha256-mhO52EWOvxHOyTFt0V1hM6Oo6mlpNo2PFlxQtcmCJBc=",
						}),
					]
						and Locks.decode(Locks.encode(locks)) == Ok(locks)
			Err(_) => False
		}
	}
	Err(_) => False
}

# JSON syntax, envelope versions and graph shape are validated, not trusted.
expect ["", "{}", "{", "null", "[]", "{\"version\":2}"]
	.all(|text| Locks.decode(text).is_err())

# Malformed hashes, wrong flake intent and stale references fail.
expect {
	bad = [
		native_fixture.replace_each("narHash", "missingHash"),
		native_fixture.replace_each("sha256-", "sha512-"),
		native_fixture.replace_each("false", "true"),
		native_fixture.replace_each("nixos-unstable", "different-branch"),
		native_fixture.replace_each("/project/assets", "/different/assets"),
		native_fixture.replace_each("\"version\": 7", "\"version\": 8"),
		native_fixture.replace_each(
			"4975466d324710c576dc11ad614684e6bd8cad8e",
			"bad",
		),
	]
	bad.all(
		|text| Locks.from_nix(
			TestData.project(TestData.data),
			TestData.layout,
			text,
		).is_err(),
	)
}

# A dangling native input edge is rejected before Nix can follow it.
expect Locks.from_nix(
	TestData.project(TestData.data),
	TestData.layout,
	native_fixture.replace_each(
		"\"default\": \"default\"",
		"\"default\": \"missing\"",
	),
).is_err()

# Cyclic follows terminate at a bounded diagnostic, not unbounded recursion.
expect Locks.from_nix(
	TestData.project(TestData.data),
	TestData.layout,
	native_fixture.replace_each(
		"\"default\": \"default\"",
		"\"default\": [\"default\"]",
	),
).is_err()

# A native graph with extra root inputs cannot be paired with an old identity.
expect Locks.from_nix(
	TestData.project(TestData.data),
	TestData.layout,
	native_fixture.replace_each(
		"\"assets\": \"assets\"",
		"\"assets\": \"assets\", \"extra\": \"assets\"",
	),
).is_err()

# Tampering normalized local nodes into absolute authority paths is rejected.
expect match locked_fixture {
	Ok(locks) => Locks.decode(
		Locks.encode(locks).replace_each(
			"\"path\":\"assets\"",
			"\"path\":\"/developer/assets\"",
		),
	).is_err()
	Err(_) => False
}

# Native fetch ownership cannot disagree with the declared original identity.
expect Locks.from_nix(
	TestData.project(TestData.data),
	TestData.layout,
	native_fixture.replace_each(
		"\"owner\": \"NixOS\",\n",
		"\"owner\": \"someone-else\",\n",
	),
).is_err()

# Omitted hosted origins mean provider defaults, not arbitrary locked hosts.
# Exercise both native observations and serialized authority for each provider.
expect [
	("github", "github.com"),
	("gitlab", "gitlab.com"),
	("sourcehut", "git.sr.ht"),
].all(
	|(kind, host)| {
		project = TestData.project({
			..TestData.data,
			sources: [
				{
					name: "default",
					provider: NixPackages("${kind}:NixOS/nixpkgs/nixos-unstable"),
				},
			],
		})
		native = native_fixture.replace_each("github", kind)
		with_host = |value| native.replace_each(
			"\"owner\": \"NixOS\",\n",
			"\"host\": \"${value}\", \"owner\": \"NixOS\",\n",
		)
		Locks.from_nix(project, TestData.layout, native).is_ok()
			and Locks.from_nix(
				project,
				TestData.layout,
				with_host("evil.example"),
			).is_err()
				and match Locks.from_nix(project, TestData.layout, with_host(host)) {
					Ok(locks) => Locks.decode(Locks.encode(locks)) == Ok(locks)
						and Locks.decode(
							Locks.encode(locks).replace_each(host, "evil.example"),
						).is_err()
					Err(_) => False
				}
	},
)

# Transitive hosted originals may spell the default explicitly; omission in
# locked is equivalent. Nondefault originals still require the identical host.
expect [
	("github", "github.com"),
	("gitlab", "gitlab.com"),
	("sourcehut", "git.sr.ht"),
].all(
	|(kind, host)| {
		native = native_fixture.replace_each("github", kind)
		with_original_host = |value| native.replace_each(
			"\"owner\": \"NixOS\", \"ref\"",
			"\"host\": \"${value}\", \"owner\": \"NixOS\", \"ref\"",
		)
		match (
			LockJson.decode(with_original_host(host)),
			LockJson.decode(with_original_host("custom.example")),
			LockJson.decode(
				with_original_host("custom.example").replace_each(
					"\"owner\": \"NixOS\",\n",
					"\"host\": \"custom.example\", \"owner\": \"NixOS\",\n",
				),
			),
		) {
			(Ok(default), Ok(custom), Ok(explicit)) =>
				Locks.validate_graph(default).is_ok()
					and Locks.validate_graph(custom).is_err()
						and Locks.validate_graph(explicit).is_ok()
			_ => False
		}
	},
)

# Object order is irrelevant; ordered overlay lists are not sets.
expect {
	a = LockJson.Object([
		{ name: "a", value: LockJson.Number("1") },
		{
			name: "b",
			value: LockJson.Array([LockJson.String("x"), LockJson.String("y")]),
		},
	])
	b = LockJson.Object([
		{
			name: "b",
			value: LockJson.Array([LockJson.String("x"), LockJson.String("y")]),
		},
		{ name: "a", value: LockJson.Number("1") },
	])
	Locks.equivalent(a, b) and !Locks.equivalent(
		LockJson.Array([LockJson.String("x"), LockJson.String("y")]),
		LockJson.Array([LockJson.String("y"), LockJson.String("x")]),
	)
}

# Normalize local spelling, rejecting escapes and non-Git SSH transport.
expect Locks.normalize_ref("path:./assets") == Ok("path:assets")
	and Locks.original("git+ssh://example.test/repo").is_ok()
		and Locks.original("tarball+ssh://example.test/archive").is_err()
			and !Locks.remote_url("tarball", "ssh://example.test/archive")
				and !Locks.remote_url("file", "ssh://example.test/file")
					and [
						"path:.",
						"path:../assets",
						"path:/assets",
						"git+file:///assets",
						"path:assets?dir=../escape",
						"path:assets%2f..",
					].all(|ref| Locks.normalize_ref(ref).is_err())

# Valid transitive follows preserve native graph structure after derivation.
expect Locks.from_nix(
	TestData.project(TestData.data),
	TestData.layout,
	native_fixture.replace_each(
		"\"default\": {\n",
		"\"default\": { \"inputs\": {\"source\": [\"assets\"]},\n",
	),
).is_ok()

# Root-only graphs isolate follows traversal from fetch/binding validation.
follows_graph : List({ name : Str, value : LockJson }) -> LockJson
follows_graph = |edges| LockJson.Object([
	{ name: "version", value: LockJson.Number("7") },
	{ name: "root", value: LockJson.String("root") },
	{
		name: "nodes",
		value: LockJson.Object([
			{
				name: "root",
				value: LockJson.Object([
					{ name: "inputs", value: LockJson.Object(edges) },
				]),
			},
		]),
	},
])

# Forty doubling paths formerly needed over 2^40 visits despite shallow depth.
expect {
	var $edges = []
	start : U64
	start = 0
	var $index = start
	while $index < 40 {
		next = LockJson.String("e${($index + 1).to_str()}")
		$edges = $edges.append({
			name: "e${$index.to_str()}",
			value: LockJson.Array([next, next]),
		})
		$index = $index + 1
	}
	graph = follows_graph(
		$edges.append({ name: "e40", value: LockJson.Array([]) }),
	)
	Locks.validate_graph(graph) == Ok({})
}

# Mutual follows cycles fail by active-edge detection, not depth exhaustion.
expect Locks.validate_graph(
	follows_graph([
		{ name: "a", value: LockJson.Array([LockJson.String("b")]) },
		{ name: "b", value: LockJson.Array([LockJson.String("a")]) },
	]),
) == Err("Nix follows cycle")

# Acyclic chains still stop before they can exhaust the recursive call stack.
expect {
	var $edges = []
	start : U64
	start = 0
	var $index = start
	while $index < 128 {
		$edges = $edges.append({
			name: "e${$index.to_str()}",
			value: LockJson.Array([
				LockJson.String("e${($index + 1).to_str()}"),
			]),
		})
		$index = $index + 1
	}
	graph = follows_graph(
		$edges.append({ name: "e128", value: LockJson.Array([]) }),
	)
	Locks.validate_graph(graph) == Err("Nix follows depth exceeds 128")
}

# Affordable paths share one total budget, even when every step is cached.
expect {
	var $path = []
	var $index = 0
	while $index < 8192 {
		$path = $path.append(LockJson.String("leaf"))
		$index = $index + 1
	}
	edges = [
		{ name: "leaf", value: LockJson.Array([]) },
		{ name: "a", value: LockJson.Array($path) },
	]
	Locks.validate_graph(follows_graph(edges)) == Ok({})
		and Locks.validate_graph(
			follows_graph(
				edges.append({ name: "b", value: LockJson.Array($path) }),
			),
		) == Err("Nix input traversal exceeds 16384 edge visits")
}

# Cached root edges cannot hide a cycle on a different node's same-named edge.
expect {
	native = native_fixture.replace_each(
		"\"assets\": \"assets\"",
		"\"assets\": \"assets\", \"step\": []",
	).replace_each(
		"\"default\": {\n",
		"\"default\": {\"inputs\": {\"prime\": [\"step\"],"
			.concat("\"step\": [\"default\", \"step\"]},\n"),
	)
	match LockJson.decode(native) {
		Ok(graph) => Locks.validate_graph(graph) == Err("Nix follows cycle")
		Err(_) => False
	}
}

# Registry originals are acceptable only when Nix resolved an immutable fetch.
expect {
	project = TestData.project({
		..TestData.data,
		sources: [
			{
				name: "default",
				provider: NixPackages("flake:nixpkgs/nixos-unstable"),
			},
		],
	})
	native = native_fixture.replace_each(
		"\"owner\": \"NixOS\", \"ref\": \"nixos-unstable\",\n"
			.concat("        \"repo\": \"nixpkgs\", \"type\": \"github\""),
		"\"id\":\"nixpkgs\",\"ref\":\"nixos-unstable\",\"type\":\"indirect\"",
	)
	Locks.from_nix(project, TestData.layout, native).is_ok()
}
