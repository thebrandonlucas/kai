# Shared normalization, reference checks and bounded graph expansion.
import Model

## Shared pure semantic boundary. Validation observes neither PATH nor the host.
## It normalizes defaults and inheritance, and is safe to repeat on its output.
Project :: [].{
	Backend : [Nix, Guix]

	valid_name : Str -> Bool
	valid_name = |name|
		!name.is_empty() and name.to_utf8().all(
			|b| letter(b) or (b >= '0' and b <= '9') or b == '-' or b == '_',
		)

	valid_task_name : Str -> Bool
	valid_task_name = |name|
		!name.is_empty() and name.split_on(".").all(valid_name)

	## An environment variable name: a letter or underscore, then letters,
	## digits or underscores.
	valid_variable_name : Str -> Bool
	valid_variable_name = |name|
		match name.to_utf8() {
			[first, .. as rest] =>
				(letter(first) or first == '_')
					and rest.all(|b| letter(b) or (b >= '0' and b <= '9') or b == '_')
			[] => Bool.False
		}

	letter : U8 -> Bool
	letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')

	clean : Str -> Bool
	clean = |text| !text.is_empty() and text.to_utf8().all(|b| b > 32 and b != 127)

	## A commit id or OpenPGP fingerprint: 40 hexadecimal digits, either case.
	forty_hex_digits : Str -> Bool
	forty_hex_digits = |text|
		text.count_utf8_bytes() == 40 and text.to_utf8().all(
			|b|
				(b >= '0' and b <= '9')
					or (b >= 'a' and b <= 'f')
					or (b >= 'A' and b <= 'F'),
		)

	## Generic syntax only. Provider grammar is checked once intent is known.
	tool : Str -> Try(Model.Tool, Str)
	tool = |text| {
		(source, name) = match text.split_on("#") {
			[suffix] => ("default", suffix)
			[prefix, suffix] => (prefix, suffix)
			_ => return Err("invalid tool reference: ${text}")
		}
		if !valid_name(source) or !clean(name) {
			return Err("invalid tool reference: ${text}")
		}
		Ok({ source, name })
	}

	## Splits a Nix attribute path on dots outside quotes. Each segment is a
	## plain identifier or a double-quoted string without `"` or `\`.
	nix_attribute_path : Str -> Try(List(Str), {})
	nix_attribute_path = |name| {
		var $segments = []
		var $segment = []
		var $segment_quoted = Bool.False
		var $inside_quotes = Bool.False
		for b in name.to_utf8() {
			if $inside_quotes {
				if b == '"' {
					$inside_quotes = Bool.False
				} else if b == '\\' {
					return Err({})
				} else {
					$segment = $segment.append(b)
				}
			} else if b == '.' {
				if $segment.is_empty() {
					return Err({})
				}
				$segments = $segments.append(Str.from_utf8($segment) ?? "")
				$segment = []
				$segment_quoted = Bool.False
			} else if b == '"' and $segment.is_empty() and !$segment_quoted {
				$inside_quotes = Bool.True
				$segment_quoted = Bool.True
			} else if !$segment_quoted and nix_identifier_byte(b) {
				$segment = $segment.append(b)
			} else {
				return Err({})
			}
		}
		if $inside_quotes or $segment.is_empty() {
			return Err({})
		}
		Ok($segments.append(Str.from_utf8($segment) ?? ""))
	}

	nix_identifier_byte : U8 -> Bool
	nix_identifier_byte = |b|
		letter(b) or (b >= '0' and b <= '9') or b == '_' or b == '-' or b == '\''

	## Deliberately conservative native grammars: Nix dotted attribute paths;
	## Guix package[@version][:output] specifications. No translation or probing.
	check_tool : Backend, Str -> Try({}, Str)
	check_tool = |backend, name| {
		if backend == Guix and name.contains("\"") {
			return Err("invalid Guix tool: ${name}: quoted segments are Nix-only")
		}
		valid = match backend {
			Nix => nix_attribute_path(name).is_ok()
			Guix => {
				parts = name.split_on(":")
				spec = parts.first() ?? ""
				versions = spec.split_on("@")
				parts.len() <= 2 and versions.len() <= 2 and
					parts.drop_first(1).all(valid_name) and
						versions.all(
							|part|
								!part.is_empty() and part.to_utf8().all(
									|b|
										letter(b) or (b >= '0' and b <= '9') or
											b == '-' or b == '_' or b == '.' or b == '+',
								),
						)
			}
		}
		if valid {
			Ok({})
		} else {
			Err("invalid ${if (backend == Nix) "Nix" else "Guix"} tool: ${name}")
		}
	}

	check_names : List(Str), Str -> Try({}, Str)
	check_names = |names, kind| {
		var $seen = []
		for name in names {
			if !(if (kind == "Task") valid_task_name(name) else valid_name(name)) {
				return Err("invalid name for ${kind}: ${name}")
			}
			if $seen.contains(name) {
				return Err("Duplicate${kind}: ${name}")
			}
			$seen = $seen.append(name)
		}
		Ok({})
	}

	valid_ref : Str -> Bool
	valid_ref = |url|
		clean(url) and [
			"github:",
			"gitlab:",
			"sourcehut:",
			"flake:",
			"git+",
			"path:",
			"file:",
			"https://",
			"http://",
			"tarball+",
			"file+",
		].any(
			|prefix|
				url.starts_with(prefix) and !url.drop_prefix(prefix).is_empty(),
		)

	hex_digit : U8 -> Try(U8, {})
	hex_digit = |byte| if byte >= '0' and byte <= '9' {
		Ok(byte - '0')
	} else if byte >= 'a' and byte <= 'f' {
		Ok(byte - 'a' + 10)
	} else if byte >= 'A' and byte <= 'F' {
		Ok(byte - 'A' + 10)
	} else Err({})

	## A sha256 hash as SRI, `sha256-<base64>`, given as SRI or 64 hex digits.
	sri_sha256 : Str -> Try(Str, {})
	sri_sha256 = |text| {
		alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
			.to_utf8()
		if text.starts_with("sha256-") {
			encoded = text.drop_prefix("sha256-").drop_suffix("=").to_utf8()
			valid = text.ends_with("=") and encoded.len() == 43
				and encoded.all(|b| alphabet.contains(b))
			return if (valid) Ok(text) else Err({})
		}
		digits = text.to_utf8().map_try(hex_digit)?.map(|digit| digit.to_u64())
		if digits.len() != 64 {
			return Err({})
		}
		# Three hex digits are two base64 digits; the last hex digit pads to one.
		var $encoded = []
		var $index = 0
		while $index < 63 {
			value = (digits.get($index) ?? 0) * 256
				+ (digits.get($index + 1) ?? 0) * 16
				+ (digits.get($index + 2) ?? 0)
			$encoded = $encoded
				.append(alphabet.get(value // 64) ?? 'A')
				.append(alphabet.get(value % 64) ?? 'A')
			$index = $index + 3
		}
		last = alphabet.get((digits.get(63) ?? 0) * 4) ?? 'A'
		Ok("sha256-".concat(Str.from_utf8($encoded.append(last)) ?? "").concat("="))
	}

	## Lexical containment only; the executor must also reject escaping symlinks.
	## Spaces are valid path bytes. Empty, dot and parent segments are not.
	valid_output : Str -> Bool
	valid_output = |path|
		!path.is_empty() and !path.contains("\\") and !path.contains(":") and
			path.to_utf8().all(|b| b >= 32 and b != 127) and
				path.split_on("/").all(
					|part| !part.is_empty() and part != "." and part != "..",
				)

	## Local locked sources must be project-relative subtrees, not the project
	## root or machine-specific absolute paths. Remote references are not fetched.
	valid_build_source_ref : Str -> Bool
	valid_build_source_ref = |ref| {
		if ref.starts_with("path:") {
			path = ref.drop_prefix("path:").drop_prefix("./")
			return clean(ref) and valid_output(path) and
				!path.contains("?") and !path.contains("#")
		}
		clean(ref) and [
			"github:",
			"gitlab:",
			"sourcehut:",
			"git+https://",
			"git+http://",
			"git+ssh://",
			"https://",
			"http://",
			"tarball+https://",
			"tarball+http://",
			"file+https://",
			"file+http://",
		].any(
			|prefix|
				ref.starts_with(prefix) and !ref.drop_prefix(prefix).is_empty(),
		)
	}

	## Portable shell names, none that Kai or the Nix builder sets itself.
	check_env : List(Model.Variable), Str -> Try({}, Str)
	check_env = |variables, declaration| {
		reserved = ["PATH", "HOME", "KAI_INPUTS", "KAI_ARTIFACTS", "out"]
		var $seen = []
		for variable in variables {
			if !valid_variable_name(variable.name) or reserved.contains(variable.name) {
				return Err("invalid Env name in ${declaration}: ${variable.name}")
			}
			if variable.value.to_utf8().contains(0) {
				return Err("NUL in Env ${variable.name}: ${declaration}")
			}
			if $seen.contains(variable.name) {
				return Err("DuplicateEnv: ${declaration}: ${variable.name}")
			}
			$seen = $seen.append(variable.name)
		}
		Ok({})
	}

	## `base` with `overrides` replacing its variables of the same name.
	merge_env : List(Model.Variable), List(Model.Variable) -> List(Model.Variable)
	merge_env = |base, overrides|
		base.keep_if(|b| !overrides.any(|o| o.name == b.name)).concat(overrides)

	## Alias names and binaries are single file names in a bin directory.
	check_aliases : List(Model.Alias), Str -> Try({}, Str)
	check_aliases = |aliases, environment| {
		file_name = |name|
			clean(name) and !name.contains("/") and name != "." and name != ".."
		var $seen = []
		for alias in aliases {
			if !file_name(alias.name) or !file_name(alias.binary) {
				return Err("invalid Alias in environment ${environment}: ${alias.name}")
			}
			if $seen.contains(alias.name) {
				return Err("DuplicateAlias: environment ${environment}: ${alias.name}")
			}
			$seen = $seen.append(alias.name)
		}
		Ok({})
	}

	## The tools an environment's packages come from, its aliases',
	## PackageEnv's and those it adds on some systems included.
	environment_tools : Model.Environment -> List(Model.Tool)
	environment_tools = |environment|
		unique(
			environment.tools
				.concat(environment.aliases.map(|alias| alias.tool))
				.concat(environment.package_env.join_map(|v| package_tools_of(v.value)))
				.concat(environment.on_systems.join_map(|o| o.tools)),
		)

	## OnSystems names only declared systems, at least one, and sets variables
	## as Env does.
	check_on_systems : Model.Environment, List(Str) -> Try({}, Str)
	check_on_systems = |environment, systems| {
		declaration = "OnSystems in environment ${environment.name}"
		for on in environment.on_systems {
			if on.systems.is_empty() {
				return Err("${declaration} names no system")
			}
			for system in on.systems {
				if !systems.contains(system) {
					return Err("${declaration} names undeclared system ${system}")
				}
			}
			check_env(on.env, declaration)?
		}
		Ok({})
	}

	## An environment as it is on `system`: what its OnSystems add there, the
	## tools after its own and the variables overriding its own, in order.
	on_system : Model.Environment, Str -> Model.Environment
	on_system = |environment, system| {
		chosen = environment.on_systems.keep_if(|on| on.systems.contains(system))
		{
			..environment,
			tools: unique(environment.tools.concat(chosen.join_map(|on| on.tools))),
			env: chosen.fold(environment.env, |env, on| merge_env(env, on.env)),
			on_systems: [],
		}
	}

	## The model as it is on `system`, for a backend that plans for the host.
	for_system : Model, Str -> Model
	for_system = |model, system| {
		..model,
		environments: model.environments.map(|e| on_system(e, system)),
	}

	## The tools a PackageEnv value names.
	package_tools_of : Model.PackageValue -> List(Model.Tool)
	package_tools_of = |value|
		match value {
			LibraryPath(tools) | BinPath(tools) => tools
			PackagePath(one) => [one]
		}

	## The variables an environment's PackageEnv sets, checked like Env's, and
	## never one its Env sets too.
	check_package_env : Model.Environment -> Try({}, Str)
	check_package_env = |environment| {
		declaration = "environment ${environment.name}"
		names = environment.package_env.map(|v| { name: v.name, value: "" })
		check_env(names, declaration)?
		for variable in environment.package_env {
			if environment.env.any(|v| v.name == variable.name) {
				return Err("Env and PackageEnv both set ${variable.name} in ${declaration}")
			}
		}
		Ok({})
	}

	## The `env` argv prefix that runs the command after it in the
	## project-relative directory `dir`, unless it is empty, with `variables`
	## set.
	env_command : Str, List(Model.Variable) -> List(Str)
	env_command = |dir, variables|
		if dir.is_empty() and variables.is_empty() {
			[]
		} else {
			chdir = if (dir.is_empty()) [] else ["--chdir=${dir}"]
			["env"].concat(chdir).concat(variables.map(|v| "${v.name}=${v.value}"))
		}

	## The secrets other tasks declare, which a task's process never receives
	## unless it declares them too, as secrets or optional environment variables.
	other_tasks_secrets : Model, Model.Task -> List(Str)
	other_tasks_secrets = |model, task| {
		received = task.secrets.concat(task.optional_environment_variables)
		model.tasks.join_map(|t| t.secrets).fold(
			[],
			|names, name|
				if names.contains(name) or received.contains(name) {
					names
				} else {
					names.append(name)
				},
		)
	}

	## Shared argv boundary for tasks and builds; arguments are never shell-split.
	check_argv : List(Str), Str -> Try({}, Str)
	check_argv = |argv, name| {
		if argv.is_empty() or (argv.first() ?? "").is_empty() {
			return Err("empty argv: ${name}")
		}
		if argv.len() > 4096 or
			argv.fold(0, |size, arg| size + arg.to_utf8().len()) > 1048576 {
			return Err("argv exceeds 4096 arguments or 1 MiB: ${name}")
		}
		if argv.any(|arg| arg.to_utf8().contains(0)) {
			return Err("NUL in argv: ${name}")
		}
		Ok({})
	}

	validate : Model -> Try(Model, Str)
	validate = |model| {
		if model.format.major != Model.current_format.major {
			return Err("unsupported model major")
		}
		if model.name.is_empty() or model.name.to_utf8().any(|b| b < 32 or b == 127) {
			return Err("invalid name for project")
		}
		if model.systems.is_empty() {
			return Err("no systems")
		}
		for system in model.systems {
			parts = system.split_on("-")
			if parts.len() != 2 or !parts.all(
				|part|
					!part.is_empty() and part.to_utf8().all(
						|b|
							(b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or
								b == '_',
					),
			) {
				return Err("invalid system: ${system}")
			}
		}
		if model.builds.len() > 1024 or model.build_sources.len() > 1024 {
			return Err("builds or build sources exceed 1024 declarations")
		}
		if model.builds.fold(
			0,
			|count, build| count + build.needs.len() + build.inputs.len(),
		) > 8192 {
			return Err("build graph exceeds 8192 references")
		}
		if !model.build_root.is_empty()
			and !model.build_root.split_on("/").all(|part| part == "..") {
			return Err("invalid BuildRoot: ${model.build_root}: use only .. segments")
		}
		if model.workflows.len() > 1024 {
			return Err("workflows exceed 1024 declarations")
		}
		if model.workflows.fold(0, |n, workflow| n + workflow.steps.len()) > 8192 {
			return Err("workflow graph exceeds 8192 steps")
		}
		check_names(model.workflows.map(|w| w.name), "Workflow")?
		check_names(model.build_sources.map(|s| s.name), "BuildSource")?
		check_names(model.builds.map(|b| b.name), "Build")?
		check_names(model.sources.map(|s| s.name), "Source")?
		check_names(model.inputs.map(|i| i.name), "Input")?
		# Guix's own channel is always present, so no other may take its name.
		channel_names = model.guix_channels.map(|c| c.name)
		check_names(["guix"].concat(channel_names), "GuixChannel")?
		for channel in model.guix_channels {
			{ commit, signer } = channel.introduction
			if !clean(channel.url) or !clean(channel.branch) or !forty_hex_digits(commit)
				or !forty_hex_digits(signer.replace_each(" ", "")) {
				return Err("invalid Guix channel: ${channel.name}")
			}
		}
		check_names(model.environments.map(|e| e.name), "Environment")?
		check_names(model.shells.map(|s| s.name), "Shell")?
		check_names(model.tasks.map(|t| t.name), "Task")?
		sources = if model.sources.any(|s| s.name == "default") {
			model.sources
		} else {
			[{ name: "default", provider: Auto }].concat(model.sources)
		}
		for source in sources {
			if model.inputs.any(|i| i.name == source.name) {
				return Err("DuplicateInput: ${source.name}")
			}
			match source.provider {
				Auto => {}
				NixPackages(url) => if !valid_ref(url) {
					return Err("invalid Nix source: ${source.name}")
				}
				GuixPackages(url) => if !clean(url) {
					return Err("invalid Guix source: ${source.name}")
				}
			}
		}
		for source in model.build_sources {
			if sources.any(|s| s.name == source.name) or
				model.inputs.any(|i| i.name == source.name) {
				return Err("DuplicateInput: ${source.name}")
			}
			if !valid_build_source_ref(source.ref) {
				return Err("invalid build source reference: ${source.name}")
			}
		}
		check_names(model.fetches.map(|f| f.name), "Fetch")?
		for fetch in model.fetches {
			if sources.any(|s| s.name == fetch.name) or
				model.inputs.any(|i| i.name == fetch.name) or
					model.build_sources.any(|s| s.name == fetch.name) {
				return Err("DuplicateInput: ${fetch.name}")
			}
			if fetch.files.is_empty() {
				return Err("Fetch ${fetch.name} has no files")
			}
			var $systems = []
			for file in fetch.files {
				if $systems.contains(file.system) or !clean(file.system) {
					return Err("DuplicateFetchSystem: ${fetch.name}: ${file.system}")
				}
				$systems = $systems.append(file.system)
				if !model.systems.contains(file.system) {
					return Err(
						"Fetch ${fetch.name} has a file for undeclared system "
							.concat(file.system),
					)
				}
				if !clean(file.url) or
					!(file.url.starts_with("https://") or file.url.starts_with("http://")) {
					return Err("invalid Fetch URL: ${fetch.name}: ${file.url}")
				}
				if sri_sha256(file.hash) != Ok(file.hash) {
					return Err("invalid Fetch hash: ${fetch.name}")
				}
			}
			for system in model.systems {
				if !$systems.contains(system) {
					return Err("Fetch ${fetch.name} has no file for system ${system}")
				}
			}
		}
		if !model.fetches.is_empty() and !model.requires_.contains("fetches") {
			return Err("fetches require feature: fetches")
		}
		check_names(model.cargo_vendors.map(|c| c.name), "CargoVendor")?
		for vendor in model.cargo_vendors {
			if sources.any(|s| s.name == vendor.name) or
				model.inputs.any(|i| i.name == vendor.name) or
					model.build_sources.any(|s| s.name == vendor.name) or
						model.fetches.any(|f| f.name == vendor.name) {
				return Err("DuplicateInput: ${vendor.name}")
			}
			# Cargo.lock pins a git checkout by the commit after its source's `#`.
			for line in vendor.lock.split_on("\n").map(|l| l.trim()) {
				commit = line.drop_suffix("\"").split_on("#").last() ?? ""
				if line.starts_with("source = \"git+")
					and !(line.ends_with("\"") and forty_hex_digits(commit)) {
					return Err("CargoVendor ${vendor.name}: a git source names no commit")
				}
			}
		}
		if !model.cargo_vendors.is_empty() and !model.requires_.contains("cargo") {
			return Err("cargo vendors require feature: cargo")
		}
		if !model.build_sources.is_empty() and !model.requires_.contains("sources") {
			return Err("build sources require feature: sources")
		}
		if !model.builds.is_empty() and !model.requires_.contains("builds") {
			return Err("builds require feature: builds")
		}
		if !model.workflows.is_empty() and !model.requires_.contains("workflows") {
			return Err("workflows require feature: workflows")
		}
		for input in model.inputs {
			if !valid_ref(input.url) {
				return Err("invalid input reference: ${input.name}")
			}
		}
		if !model.follows.is_empty() and !model.requires_.contains("follows") {
			return Err("Follows require feature: follows")
		}
		var $followed = []
		for follows in model.follows {
			{ overlay, input, source } = follows
			if !model.inputs.any(|i| i.name == overlay and i.kind == Overlay) {
				return Err("unknown overlay: ${overlay}")
			}
			if !valid_name(input) or $followed.contains((overlay, input)) {
				return Err("invalid or duplicate Follows input of ${overlay}: ${input}")
			}
			$followed = $followed.append((overlay, input))
			match sources.find_first(|s| s.name == source) {
				Ok({ provider: GuixPackages(_), .. }) | Err(_) =>
					return Err("Follows needs a Nix package source: ${source}")
				Ok(_) => {}
			}
		}
		var $environments = []
		for env in model.environments {
			check_env(env.env, "environment ${env.name}")?
			check_package_env(env)?
			match env.rust_toolchain {
				Toml(text) if text.is_empty() or text.to_utf8().contains(0) =>
					return Err("invalid RustToolchain in environment ${env.name}")
				_ => {}
			}
			check_on_systems(env, model.systems)?
			resolved = resolve(model.environments, env.name, [])?
			for variable in resolved.on_systems.join_map(|o| o.env) {
				if resolved.package_env.any(|v| v.name == variable.name) {
					return Err(
						"Env and PackageEnv both set ${variable.name} in environment ${env.name}",
					)
				}
			}
			check_aliases(resolved.aliases, env.name)?
			for t in environment_tools(resolved) {
				parsed = tool("${t.source}#${t.name}")?
				if model.fetches.any(|f| f.name == parsed.source) {
					if !valid_name(t.name) {
						return Err("invalid executable name for Fetch ${t.source}: ${t.name}")
					}
				} else {
					source = sources.find_first(|s| s.name == parsed.source)
						.map_err(|_| "unknown source: ${t.source}")?
					match source.provider {
						Auto => {}
						NixPackages(_) => {
							check_tool(Nix, t.name)?
						}
						GuixPackages(_) => {
							check_tool(Guix, t.name)?
						}
					}
				}
			}
			for overlay in resolved.overlays {
				if !model.inputs.any(|i| i.name == overlay and i.kind == Overlay) {
					return Err("unknown overlay: ${overlay}")
				}
			}
			$environments = $environments.append(resolved)
		}
		for shell in model.shells {
			if !$environments.any(|e| e.name == shell.environment) {
				return Err("unknown environment: ${shell.environment}")
			}
		}
		for task in model.tasks {
			if !$environments.any(|e| e.name == task.environment) {
				return Err("unknown environment: ${task.environment}")
			}
			check_argv(task.run, task.name)?
			check_env(task.env, "task ${task.name}")?
			if !task.dir.is_empty() and !valid_output(task.dir) {
				return Err("invalid Dir in task ${task.name}: ${task.dir}")
			}
			for secret in task.secrets {
				if !valid_variable_name(secret) {
					return Err("invalid secret name in task ${task.name}")
				}
			}
			for name in task.optional_environment_variables {
				if !valid_variable_name(name) {
					return Err(
						"invalid optional environment variable name in task ${task.name}",
					)
				}
				if task.secrets.contains(name) {
					return Err(
						"task ${task.name} declares ${name} in both Secrets and "
							.concat("OptionalEnvironmentVariables"),
					)
				}
			}
			check_names(task.needs, "BuildDependency")?
			for need in task.needs {
				if !model.builds.any(|b| b.name == need) {
					return Err("unknown build: ${need}")
				}
			}
		}
		defaults = model.builds.keep_if(|b| b.default).map(|b| b.name)
		if defaults.len() > 1 {
			return Err("several builds are Default: ${Str.join_with(defaults, ", ")}")
		}
		for build in model.builds {
			if !$environments.any(|e| e.name == build.environment) {
				return Err("unknown environment: ${build.environment}")
			}
			check_argv(build.run, build.name)?
			check_env(build.env, "build ${build.name}")?
			if !valid_output(build.output) {
				return Err("invalid build output: ${build.name}: ${build.output}")
			}
			files = match build.files {
				All => []
				Only(paths) => paths
			}
			for path in files {
				if !valid_output(path) {
					return Err("invalid build file: ${build.name}: ${path}")
				}
			}
			check_names(build.inputs, "BuildInput")?
			check_names(build.needs, "BuildDependency")?
			for input in build.inputs {
				if !model.build_sources.any(|s| s.name == input) and
					!model.fetches.any(|f| f.name == input) and
						!model.cargo_vendors.any(|c| c.name == input) {
					return Err("unknown build source: ${input}")
				}
			}
		}
		var $done = []
		for build in model.builds {
			$done = visit_build(model.builds, build.name, [], $done)?
		}
		_ = workflow_graph(model)?
		var $extensions = []
		for extension in model.extensions {
			if !clean(extension.kind) or !clean(extension.name) {
				return Err("empty Custom kind or name")
			}
			key = (extension.kind, extension.name)
			if $extensions.contains(key) {
				return Err("DuplicateExtension: ${extension.kind}/${extension.name}")
			}
			$extensions = $extensions.append(key)
		}
		for raw in model.raw {
			if !clean(raw.backend) or !clean(raw.target) {
				return Err("empty Raw backend or target")
			}
		}
		Ok(
			Model.{
				format: model.format,
				name: model.name,
				requires_: model.requires_,
				systems: unique(model.systems),
				sources,
				guix_channels: model.guix_channels,
				inputs: model.inputs,
				follows: model.follows,
				environments: $environments,
				shells: model.shells,
				tasks: model.tasks,
				build_sources: model.build_sources,
				fetches: model.fetches,
				cargo_vendors: model.cargo_vendors,
				build_root: model.build_root,
				builds: model.builds,
				workflows: model.workflows,
				extensions: model.extensions,
				raw: model.raw,
			},
		)
	}

	## Whole-project checks precede expansion, even for an empty request.
	## Only atomic typed steps escape; repeated effects stay repeated.
	workflow_steps : Model, Str -> Try(List(Model.AtomicStep), Str)
	workflow_steps = |model, name| {
		project = validate(model)?
		graph = workflow_graph(project)?
		expand_workflow(graph, name, [])
	}

	## Cache size and height, not expanded lists. Every declaration/edge is
	## visited once, including diamonds whose leaves contain no atomic steps.
	WorkflowVisit : {
		name : Str,
		height : U64,
		count : U64,
		argv_bytes : U64,
		steps : List(Model.WorkflowStep),
	}

	workflow_graph : Model -> Try(List(WorkflowVisit), Str)
	workflow_graph = |model| {
		var $done = []
		for workflow in model.workflows {
			$done = visit_workflow(
				model.workflows,
				model.tasks,
				model.builds,
				workflow.name,
				[],
				$done,
			)?
		}
		Ok($done)
	}

	visit_workflow :
		List(Model.Workflow),
		List(Model.Task),
		List(Model.Build),
		Str,
		List(Str),
		List(WorkflowVisit) ->
			Try(
				List(WorkflowVisit),
				Str,
			)
	visit_workflow = |workflows, tasks, builds, name, visiting, done| {
		if visiting.contains(name) {
			path = Str.join_with(visiting.append(name), " -> ")
			return Err("workflow cycle: ${path}")
		}
		if visiting.len() >= 128 {
			return Err("workflow dependencies exceed 128 levels")
		}
		match done.find_first(|entry| entry.name == name) {
			Ok(entry) => {
				if visiting.len() + entry.height > 128 {
					return Err("workflow dependencies exceed 128 levels")
				}
				return Ok(done)
			}
			Err(_) => {}
		}
		workflow = workflows.find_first(|w| w.name == name)
			.map_err(|_| "unknown workflow: ${name}")?
		var $done = done
		var $height = 1.U64
		var $count = 0.U64
		var $argv_bytes = 0.U64
		var $productive = []
		for step in workflow.steps {
			match wrapped(step) {
				RunTask(task_name, argv) => {
					task = tasks.find_first(|t| t.name == task_name)
						.map_err(|_| "unknown task: ${task_name}")?
					# Validate configured plus extra argv, without shell parsing.
					run = task.run.concat(argv)
					check_argv(run, task_name)?
					$productive = $productive.append(step)
					$count = $count + 1
					$argv_bytes = $argv_bytes +
						run.fold(0, |size, arg| size + arg.to_utf8().len())
				}
				BuildArtifact(build_name) => {
					if !builds.any(|b| b.name == build_name) {
						return Err("unknown build: ${build_name}")
					}
					$productive = $productive.append(step)
					$count = $count + 1
				}
				RunWorkflow(child) => {
					$done = visit_workflow(
						workflows,
						tasks,
						builds,
						child,
						visiting.append(name),
						$done,
					)?
					entry = $done.find_first(|e| e.name == child)
						.map_err(|_| "unknown workflow: ${child}")?
					$height = if entry.height + 1 > $height {
						entry.height + 1
					} else {
						$height
					}
					if entry.count > 0 {
						$productive = $productive.append(step)
					}
					$count = $count + entry.count
					$argv_bytes = $argv_bytes + entry.argv_bytes
				}
				MayFail(_) => {}
			}
			# Reject while counting, before allocating any expanded output.
			if $count > 4096 {
				return Err("workflow expansion exceeds 4096 atomic steps")
			}
			if $argv_bytes > 1048576 {
				return Err("workflow expansion exceeds 1 MiB argv bytes")
			}
		}
		Ok(
			$done.append({
				name,
				height: $height,
				count: $count,
				argv_bytes: $argv_bytes,
				steps: $productive,
			}),
		)
	}

	## Validation filters zero-sized edges once, including empty diamonds.
	## Expansion visits at most output size * depth productive edges.
	Steps : List(Model.AtomicStep)

	expand_workflow : List(WorkflowVisit), Str, Steps -> Try(Steps, Str)
	expand_workflow = |graph, name, steps| {
		entry = graph.find_first(|e| e.name == name)
			.map_err(|_| "unknown workflow: ${name}")?
		if entry.count == 0 {
			return Ok(steps)
		}
		expand_steps(graph, entry.steps, steps)
	}

	## A MayFail step expands to MayFail(n) before its n atomic steps.
	expand_steps :
		List(WorkflowVisit), List(Model.WorkflowStep), Steps -> Try(Steps, Str)
	expand_steps = |graph, declared, steps| {
		var $steps = steps
		for step in declared {
			match step {
				RunTask(task, argv) => {
					$steps = $steps.append(RunTask(task, argv))
				}
				BuildArtifact(build) => {
					$steps = $steps.append(BuildArtifact(build))
				}
				RunWorkflow(child) => {
					$steps = expand_workflow(graph, child, $steps)?
				}
				MayFail(_) => {
					group = expand_steps(graph, [wrapped(step)], [])?
					count = group.count_if(
						|s| match s {
							MayFail(_) => Bool.False
							_ => Bool.True
						},
					)
					$steps = $steps.append(MayFail(count)).concat(group)
				}
			}
		}
		Ok($steps)
	}

	## The step a MayFail wraps, else the step itself.
	wrapped : Model.WorkflowStep -> Model.WorkflowStep
	wrapped = |step|
		match step {
			MayFail(RunTask(task, argv)) => RunTask(task, argv)
			MayFail(BuildArtifact(build)) => BuildArtifact(build)
			MayFail(RunWorkflow(child)) => RunWorkflow(child)
			other => other
		}

	## Validate the whole project before returning the requested closure. Each
	## dependency appears once, before its consumers, in Needs declaration order.
	build_closure : Model, Str -> Try(List(Model.Build), Str)
	build_closure = |model, name| builds_closure(model, [name])

	builds_closure : Model, List(Str) -> Try(List(Model.Build), Str)
	builds_closure = |model, names| {
		project = validate(model)?
		var $done = []
		for name in names {
			$done = visit_build(project.builds, name, [], $done)?
		}
		Ok($done.map(|entry| entry.build))
	}

	## The directory builds copy: the project root, or its ancestor the
	## model's BuildRoot names, which must lie below the filesystem root.
	snapshot_root : Model, Str -> Try(Str, Str)
	snapshot_root = |model, project_root| {
		if model.build_root.is_empty() {
			return Ok(project_root)
		}
		parts = project_root.split_on("/").drop_first(1)
		up = model.build_root.split_on("/").len()
		if up >= parts.len() {
			return Err(
				"BuildRoot ${model.build_root} reaches the filesystem root "
					.concat("from ${project_root}"),
			)
		}
		Ok("/".concat(Str.join_with(parts.drop_last(up), "/")))
	}

	## What a closure's shared snapshot holds: the files each build selects.
	snapshot_files : List(Model.Build) -> [All, Only(List(Str))]
	snapshot_files = |builds|
		builds.fold(
			Only([]),
			|selected, build|
				match (selected, build.files) {
					(Only(chosen), Only(paths)) => Only(chosen.concat(paths))
					_ => All
				},
		)

	## The variable that gives a task with Needs its artifacts directory, one
	## entry per needed build, under the workspace.
	artifacts_variable : Model.Task, Str -> List(Model.Variable)
	artifacts_variable = |task, workspace|
		if task.needs.is_empty() {
			[]
		} else {
			[{ name: "KAI_ARTIFACTS", value: "${workspace}/artifacts-${task.name}" }]
		}

	## Memoized DAG traversal avoids exponential diamond expansion. Height is
	## retained so memo hits cannot hide a path exceeding the 128-level bound.
	BuildVisit : { build : Model.Build, height : U64 }
	Builds : List(Model.Build)

	visit_build :
		Builds, Str, List(Str), List(BuildVisit) -> Try(List(BuildVisit), Str)
	visit_build = |builds, name, visiting, done| {
		if visiting.contains(name) {
			return Err("build cycle: ${Str.join_with(visiting.append(name), " -> ")}")
		}
		if visiting.len() >= 128 {
			return Err("build dependencies exceed 128 levels")
		}
		match done.find_first(|entry| entry.build.name == name) {
			Ok(entry) => {
				if visiting.len() + entry.height > 128 {
					return Err("build dependencies exceed 128 levels")
				}
				return Ok(done)
			}
			Err(_) => {}
		}
		build = builds.find_first(|b| b.name == name)
			.map_err(|_| "unknown build: ${name}")?
		var $done = done
		var $height = 1.U64
		for need in build.needs {
			$done = visit_build(builds, need, visiting.append(name), $done)?
			dependency = $done.find_first(|entry| entry.build.name == need)
				.map_err(|_| "unknown build: ${need}")?
			$height = if dependency.height + 1 > $height {
				dependency.height + 1
			} else {
				$height
			}
		}
		Ok($done.append({ build, height: $height }))
	}

	## Bounded ancestry traversal also protects an untrusted runtime model.
	resolve :
		List(Model.Environment), Str, List(Str) -> Try(Model.Environment, Str)
	resolve = |environments, name, visiting| {
		if visiting.contains(name) {
			return Err(
				"environment cycle: ${Str.join_with(visiting.append(name), " -> ")}",
			)
		}
		if visiting.len() >= 128 {
			return Err("environment inheritance exceeds 128 levels")
		}
		env = environments.find_first(|e| e.name == name)
			.map_err(|_| "unknown environment: ${name}")?
		match env.parents {
			[] =>
				Ok({
					..env,
					tools: unique(env.tools),
					overlays: unique(env.overlays),
					aliases: unique(env.aliases),
				})
			[parent] => {
				base = resolve(environments, parent, visiting.append(name))?
				Ok({
					name: env.name,
					parents: [],
					tools: unique(base.tools.concat(env.tools)),
					overlays: unique(base.overlays.concat(env.overlays)),
					env: merge_env(
						base.env.keep_if(|b| !env.package_env.any(|o| o.name == b.name)),
						env.env,
					),
					package_env: base.package_env
						.keep_if(
							|b| !env.env.any(|o| o.name == b.name)
								and !env.package_env.any(|o| o.name == b.name),
						)
						.concat(env.package_env),
					pure: base.pure or env.pure,
					aliases: unique(base.aliases.concat(env.aliases)),
					rust_toolchain: match env.rust_toolchain {
						None => base.rust_toolchain
						own => own
					},
					# The child's own variables override the parent's on every
					# system, as its OnSystems override them on theirs.
					on_systems: base.on_systems
						.map(
							|on| {
								..on,
								env: on.env.keep_if(
									|b| !env.env.any(|o| o.name == b.name)
										and !env.package_env.any(|o| o.name == b.name),
								),
							},
						)
						.concat(env.on_systems),
				})
			}
			_ => Err("environment ${name} has several parents")
		}
	}

	## Check only the requested environment's normalized dependency closure.
	## This models Guix shell capability without implementing a Guix executor.
	check_environment : Model, Backend, Str -> Try({}, Str)
	check_environment = |model, backend, name| {
		project = validate(model)?
		env = project.environments.find_first(|e| e.name == name)
			.map_err(|_| "unknown environment: ${name}")?
		if backend == Guix and !env.overlays.is_empty() {
			return Err("Guix does not support overlays in environment ${name}")
		}
		if backend == Guix and !env.aliases.is_empty() {
			return Err("Alias needs Nix: environment ${name}")
		}
		if backend == Guix and env.rust_toolchain != None {
			return Err("RustToolchain needs Nix: environment ${name}")
		}
		if backend == Guix and !env.package_env.is_empty() {
			return Err("PackageEnv needs Nix: environment ${name}")
		}
		every_tool = environment_tools(env)
		tools = package_tools(every_tool, project.fetches)
		if backend == Guix and tools.len() != every_tool.len() {
			return Err("Guix cannot use Fetch tools, in environment ${name}")
		}
		# An empty environment still uses the default provider's environment builder.
		source_names = if tools.is_empty() {
			["default"]
		} else {
			unique(tools.map(|t| t.source))
		}
		for source_name in source_names {
			source = project.sources.find_first(|s| s.name == source_name)
				.map_err(|_| "unknown source: ${source_name}")?
			match (backend, source.provider) {
				(Nix, GuixPackages(_)) =>
					return Err("source ${source.name} requires Guix, not Nix")
				(Guix, NixPackages(_)) =>
					return Err("source ${source.name} requires Nix, not Guix")
				_ => {}
			}
		}
		for t in tools {
			check_tool(backend, t.name)?
		}
		Ok({})
	}

	## The tools that come from package sources, not from Fetches.
	package_tools : List(Model.Tool), List(Model.Fetch) -> List(Model.Tool)
	package_tools = |tools, fetches|
		tools.keep_if(|t| !fetches.any(|f| f.name == t.source))

	unique : List(a) -> List(a) where [a.is_eq : a, a -> Bool]
	unique = |items|
		items.fold([], |acc, item| if (acc.contains(item)) acc else acc.append(item))
}

# A sha256 in hex or SRI normalizes to SRI; other text is not a sha256.
expect {
	sri = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
	hex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	Project.sri_sha256(hex) == Ok(sri) and Project.sri_sha256(sri) == Ok(sri)
		and Project.sri_sha256("e3b0").is_err()
}

# A bare tool name resolves against the implicit "default" source.
expect Project.tool("git") == Ok({ source: "default", name: "git" })

# The first "#" splits source from name; the name keeps "@" and ":" intact.
expect Project.tool("stable#python@3.12:out") ==
	Ok({ source: "stable", name: "python@3.12:out" })

# More than one "#" separator is ambiguous and rejected.
expect Project.tool("bad##git").is_err()

# Control characters such as a newline make a tool name unclean.
expect Project.tool("git\n").is_err()

# Nix attribute paths may be dotted package-set selections.
expect Project.check_tool(Nix, "python3Packages.requests").is_ok()

# Nix identifiers may start with a digit, as real nixpkgs attributes do.
expect Project.check_tool(Nix, "7zip").is_ok() and
	Project.check_tool(Nix, "2bwm").is_ok()

# Guix version syntax is not a valid Nix attribute path.
expect Project.check_tool(Nix, "python@3").is_err()

# Guix accepts package@version:output specifications.
expect Project.check_tool(Guix, "python@3.12:out").is_ok()

# A Guix specification allows at most one output separator.
expect Project.check_tool(Guix, "git::out").is_err()

# Guix package and version segments may contain "+" and ".".
expect Project.check_tool(Guix, "g++@12.3:lib").is_ok()

# These fixtures use the public model and validation boundary, not resolve
# internals.
fixture : List(Model.Environment) -> Model
fixture = |environments| Model.{
	format: Model.current_format,
	name: "semantic tests",
	requires_: [],
	systems: ["x86_64-linux"],
	sources: [
		{ name: "nix", provider: NixPackages("github:NixOS/nixpkgs/nixos-unstable") },
		{
			name: "guix",
			provider: GuixPackages("https://git.savannah.gnu.org/git/guix.git"),
		},
	],
	guix_channels: [],
	inputs: [
		{ name: "first", url: "github:example/first", kind: Overlay },
		{ name: "second", url: "github:example/second", kind: Overlay },
		{ name: "data", url: "github:example/data", kind: Flake },
	],
	follows: [],
	environments,
	shells: [],
	tasks: [],
	build_sources: [],
	fetches: [],
	cargo_vendors: [],
	build_root: "",
	builds: [],
	workflows: [],
	extensions: [],
	raw: [],
}

base : Model.Environment
base = {
	name: "base",
	parents: [],
	tools: [{ source: "default", name: "git" }],
	overlays: ["first"],
	env: [],
	pure: Bool.False,
	aliases: [],
	rust_toolchain: None,
	package_env: [],
	on_systems: [],
}

child : Model.Environment
child = {
	name: "dev",
	parents: ["base"],
	tools: [
		{ source: "default", name: "python3" },
		{ source: "default", name: "git" },
	],
	overlays: ["first", "second"],
	env: [],
	pure: Bool.False,
	aliases: [],
	rust_toolchain: None,
	package_env: [],
	on_systems: [],
}

# Declaration order is irrelevant; inheritance order is not. First wins.
expect Project.validate(fixture([child, base])) == Project.validate(
	fixture([
		{
			name: "dev",
			parents: [],
			tools: [
				{ source: "default", name: "git" },
				{ source: "default", name: "python3" },
			],
			overlays: ["first", "second"],
			env: [],
			pure: Bool.False,
			aliases: [],
			rust_toolchain: None,
			package_env: [],
			on_systems: [],
		},
		base,
	]),
)

# An explicitly empty child inherits; an independent empty env stays empty.
expect match Project.validate(
	fixture([
		base,
		{
			..child,
			tools: [],
			overlays: [],
			env: [],
			pure: Bool.False,
			aliases: [],
			rust_toolchain: None,
			package_env: [],
			on_systems: [],
		},
		{
			name: "empty",
			parents: [],
			tools: [],
			overlays: [],
			env: [],
			pure: Bool.False,
			aliases: [],
			rust_toolchain: None,
			package_env: [],
			on_systems: [],
		},
	]),
) {
	Ok(model) => model.environments == [
		base,
		{ ..base, name: "dev" },
		{
			name: "empty",
			parents: [],
			tools: [],
			overlays: [],
			env: [],
			pure: Bool.False,
			aliases: [],
			rust_toolchain: None,
			package_env: [],
			on_systems: [],
		},
	]
	Err(_) => False
}

# Validation can be repeated by frontend, loader, and backend without changes.
expect match Project.validate(fixture([base, child])) {
	Ok(model) => Project.validate(model) == Ok(model) and
		model.sources.first() == Ok({ name: "default", provider: Auto })
	Err(_) => False
}

# Environment names are unique across the whole project.
expect Project.validate(fixture([base, base])) ==
	Err("DuplicateEnvironment: base")

# A parent must be declared, not merely referenced.
expect Project.validate(fixture([child])) == Err("unknown environment: base")

# Self-inheritance is a cycle.
expect Project.validate(fixture([{ ..base, parents: ["base"] }])).is_err()

# Mutual inheritance between two environments is a cycle.
expect Project.validate(fixture([{ ..base, parents: ["dev"] }, child])).is_err()

# Multiple parents are rejected, even when they name the same environment.
expect Project.validate(
	fixture([base, { ..child, parents: ["base", "base"] }]),
).is_err()

# Tools naming an undeclared source report that source.
expect Project.validate(
	fixture([{ ..base, tools: [{ source: "missing", name: "git" }] }]),
) == Err("unknown source: missing")

# Overlays must name a declared input.
expect Project.validate(fixture([{ ..base, overlays: ["missing"] }])) ==
	Err("unknown overlay: missing")

# A declared flake input is not an overlay input.
expect Project.validate(fixture([{ ..base, overlays: ["data"] }])) ==
	Err("unknown overlay: data")

# A tool name cannot smuggle a second source separator.
expect Project.validate(
	fixture([{ ..base, tools: [{ source: "default", name: "git#extra" }] }]),
).is_err()

# Environment names cannot contain path separators.
expect Project.validate(fixture([{ ..base, name: "bad/name" }])).is_err()

# Explicit providers validate grammar statically; Auto waits for selection.
expect Project.validate(
	fixture([{ ..base, tools: [{ source: "nix", name: "python@3" }] }]),
).is_err()

# An explicit Guix source rejects an empty version after "@".
expect Project.validate(
	fixture([
		{ ..base, overlays: [], tools: [{ source: "guix", name: "python@" }] },
	]),
).is_err()

# Auto sources defer grammar checks to the backend requested for the shell.
expect {
	model = fixture([
		{
			..base,
			overlays: [],
			tools: [{ source: "default", name: "python@3:out" }],
		},
	])
	Project.validate(model).is_ok() and
		Project.check_environment(model, Guix, "base").is_ok() and
			Project.check_environment(model, Nix, "base").is_err()
}

# An unused overlay/foreign source is not a global backend requirement.
expect {
	model = fixture([
		base,
		{
			name: "plain",
			parents: [],
			overlays: [],
			env: [],
			pure: Bool.False,
			aliases: [],
			rust_toolchain: None,
			package_env: [],
			on_systems: [],
			tools: [{ source: "guix", name: "git" }],
		},
	])
	Project.check_environment(model, Nix, "base").is_ok() and
		Project.check_environment(model, Guix, "plain").is_ok() and
			Project.check_environment(model, Nix, "plain").is_err() and
				Project.check_environment(model, Guix, "base").is_err()
}

# Capabilities belong to the request, even with an explicit source constraint.
expect {
	model = fixture([
		{ ..base, tools: [{ source: "guix", name: "git" }] },
		{ ..child, parents: [], overlays: [] },
	])
	Project.validate(model).is_ok() and
		Project.check_environment(model, Nix, "dev").is_ok() and
			Project.check_environment(model, Guix, "base").is_err() and
				Project.check_environment(model, Nix, "base").is_err()
}

# A Guix request cannot use a tool pinned to an explicit Nix source.
expect Project.check_environment(
	fixture([{ ..base, overlays: [], tools: [{ source: "nix", name: "git" }] }]),
	Guix,
	"base",
).is_err()

# Checking an undeclared environment fails instead of passing vacuously.
expect Project.check_environment(fixture([base]), Nix, "missing").is_err()

# Runtime callers must not bypass validation by constructing model directly.
expect Project.validate(Model.empty("empty")).is_err()

# Names reject path separators and control characters.
expect !Project.valid_name("unsafe/name") and !Project.valid_name("line\nbreak")

# Task names may be dotted, but every dotted segment must be nonempty.
expect Project.valid_task_name("check.fmt") and
	!Project.valid_task_name("check..fmt")

build_fixture : List(Model.Build) -> Model
build_fixture = |builds| Model.{
	format: Model.current_format,
	name: "build tests",
	requires_: ["sources", "builds"],
	systems: ["x86_64-linux"],
	sources: [],
	guix_channels: [],
	inputs: [],
	follows: [],
	environments: [
		{
			name: "builder",
			parents: [],
			tools: [],
			overlays: [],
			env: [],
			pure: Bool.False,
			aliases: [],
			rust_toolchain: None,
			package_env: [],
			on_systems: [],
		},
	],
	shells: [],
	tasks: [],
	build_sources: [{ name: "assets", ref: "path:./assets" }],
	fetches: [],
	cargo_vendors: [],
	build_root: "",
	builds,
	workflows: [],
	extensions: [],
	raw: [],
}

library : Model.Build
library = {
	name: "library",
	environment: "builder",
	inputs: ["assets"],
	needs: [],
	run: [
		"python3",
		"build.py",
		"",
		"two words",
		"\"quoted\"",
		"$HOME",
		"line\nbreak",
	],
	output: "dist/library",
	files: All,
	description: "",
	env: [],
	revision: Bool.False,
	default: Bool.False,
}

application : Model.Build
application = { ..library, name: "app", needs: ["library"], output: "dist/app" }

# Public codec/semantic round trip preserves exact argv, source and artifact
# data.
expect {
	model = build_fixture([application, library])
	match Project.validate(model) {
		Ok(project) => Project.validate(project) == Ok(project)
			and project.builds == [application, library]
		Err(_) => False
	}
}

# A closure lists dependencies before the requested build.
expect Project.build_closure(build_fixture([application, library]), "app") ==
	Ok([library, application])

# A closure of a leaf build contains only that build.
expect Project.build_closure(
	build_fixture([application, library]),
	"library",
) == Ok([library])

# Requesting an undeclared build is an explicit error.
expect Project.build_closure(build_fixture([library]), "missing") ==
	Err("unknown build: missing")

# A shared diamond dependency appears once, in Needs declaration order.
expect {
	left = { ..library, name: "left", needs: ["library"] }
	right = { ..library, name: "right", needs: ["library"] }
	diamond = { ..application, needs: ["left", "right"] }
	Project.build_closure(
		build_fixture([diamond, right, left, library]),
		"app",
	) == Ok([library, left, right, diamond])
}

# Build names are unique across the project.
expect Project.validate(build_fixture([library, library])) ==
	Err("DuplicateBuild: library")

# Build names cannot contain path separators.
expect Project.validate(
	build_fixture([{ ..library, name: "bad/name" }]),
).is_err()

# A build must run in a declared environment.
expect Project.validate(
	build_fixture([{ ..library, environment: "missing" }]),
) == Err("unknown environment: missing")

# Build inputs must name declared build sources.
expect Project.validate(build_fixture([{ ..library, inputs: ["missing"] }])) ==
	Err("unknown build source: missing")

# A build cannot list the same input twice.
expect Project.validate(
	build_fixture([{ ..library, inputs: ["assets", "assets"] }]),
).is_err()

# Build dependencies must name declared builds.
expect Project.validate(build_fixture([{ ..library, needs: ["missing"] }])) ==
	Err("unknown build: missing")

# A build cannot list the same dependency twice.
expect Project.validate(
	build_fixture([library, { ..application, needs: ["library", "library"] }]),
).is_err()

# A self-dependency is reported as a cycle with its path.
expect Project.validate(build_fixture([{ ..library, needs: ["library"] }])) ==
	Err("build cycle: library -> library")

# Mutual build dependencies form a cycle.
expect Project.validate(
	build_fixture([application, { ..library, needs: ["app"] }]),
).is_err()

# Even an unrequested malformed build is rejected before returning a closure.
expect Project.build_closure(
	build_fixture([library, { ..application, needs: ["app"] }]),
	"library",
).is_err()

# A build needs at least a program to run.
expect Project.validate(build_fixture([{ ..library, run: [] }])) ==
	Err("empty argv: library")

# An empty program name counts as empty argv.
expect Project.validate(build_fixture([{ ..library, run: [""] }])) ==
	Err("empty argv: library")

# A NUL byte cannot be passed through exec, so argv rejects it.
expect Project.validate(
	build_fixture([{ ..library, run: ["cmd", Str.from_utf8([0]) ?? ""] }]),
) == Err("NUL in argv: library")

# Outputs must be clean project-relative paths below the project root.
expect [
	"",
	"/absolute",
	".",
	"..",
	"./artifact",
	"dist/../escape",
	"dist//file",
	"dist/",
	"C:/file",
	"dist\\file",
	"line\nbreak",
].all(
	|output|
		Project.validate(build_fixture([{ ..library, output }])).is_err(),
)

# Spaces are valid output path bytes.
expect Project.validate(
	build_fixture([{ ..library, output: "dist/my artifact" }]),
).is_ok()

# Relative local subtrees and remote references are valid build sources.
expect [
	"path:./assets",
	"path:assets",
	"github:example/assets",
	"git+https://example.test/assets.git",
	"https://example.test/assets.tar.gz",
].all(Project.valid_build_source_ref)

# Registry, root, absolute, escaping, query and empty sources are rejected.
expect [
	"",
	"flake:nixpkgs",
	"path:.",
	"path:./",
	"path:/absolute",
	"path:../escape",
	"path:./assets/../escape",
	"path:assets?dir=../escape",
	"file:/absolute",
	"git+file:///absolute",
	"github:",
	"https://",
	"path:line\nbreak",
].all(|ref| !Project.valid_build_source_ref(ref))

# Direct model fixtures test missing feature markers and source checks.
build_source_fixture : List(Model.BuildSource), List(Str) -> Model
build_source_fixture = |build_sources, requires_| {
	model = build_fixture([library])
	Model.{
		format: model.format,
		name: model.name,
		requires_,
		systems: model.systems,
		sources: model.sources,
		guix_channels: model.guix_channels,
		inputs: model.inputs,
		follows: model.follows,
		environments: model.environments,
		shells: model.shells,
		tasks: model.tasks,
		build_sources,
		fetches: [],
		cargo_vendors: [],
		build_root: model.build_root,
		builds: model.builds,
		workflows: model.workflows,
		extensions: model.extensions,
		raw: model.raw,
	}
}

# Declared build sources require the "sources" feature marker.
expect Project.validate(
	build_source_fixture([{ name: "assets", ref: "path:./assets" }], ["builds"]),
) == Err("build sources require feature: sources")

# Declared builds require the "builds" feature marker.
expect Project.validate(
	build_source_fixture([{ name: "assets", ref: "path:./assets" }], ["sources"]),
) == Err("builds require feature: builds")

# Build sources cannot escape the project with parent segments.
expect Project.validate(
	build_source_fixture(
		[{ name: "assets", ref: "path:../escape" }],
		["sources", "builds"],
	),
).is_err()

# Build sources share one namespace with package sources and inputs.
expect Project.validate(
	build_source_fixture(
		[{ name: "default", ref: "path:./assets" }],
		["sources", "builds"],
	),
) == Err("DuplicateInput: default")

# Build source names are unique.
expect Project.validate(
	build_source_fixture(
		[
			{ name: "assets", ref: "path:./assets" },
			{ name: "assets", ref: "path:./other" },
		],
		["sources", "builds"],
	),
) == Err("DuplicateBuildSource: assets")

# Build source names cannot contain path separators.
expect Project.validate(
	build_source_fixture(
		[{ name: "bad/name", ref: "path:./assets" }],
		["sources", "builds"],
	),
).is_err()

# Increasing-order declarations exercise cached heights, not just active
# ancestry.
chain_fixture : U64 -> List(Model.Build)
chain_fixture = |count| {
	var $builds = []
	var $index = 0.U64
	while $index < count {
		name = $index.to_str()
		needs = if ($index == 0) [] else [($index - 1).to_str()]
		$builds = $builds.append({ ..library, name, needs })
		$index = $index + 1
	}
	$builds
}

# A dependency chain exactly 128 levels deep is allowed.
expect Project.validate(build_fixture(chain_fixture(128))).is_ok()

# One level past the bound fails when heights come from the memo.
expect Project.validate(build_fixture(chain_fixture(129))) ==
	Err("build dependencies exceed 128 levels")

# Reverse declaration order hits the same bound through active ancestry.
expect Project.validate(
	build_fixture(
		chain_fixture(129).fold([], |acc, build| [build].concat(acc)),
	),
) == Err("build dependencies exceed 128 levels")

# Build declarations are capped at 1024.
expect Project.validate(build_fixture(chain_fixture(1025))) ==
	Err("builds or build sources exceed 1024 declarations")

# Total build references are capped before graph traversal.
expect {
	many = chain_fixture(1024)
	names = many.map(|build| build.name)
	Project.validate(
		build_fixture(many.map(|build| { ..build, needs: names })),
	) == Err("build graph exceeds 8192 references")
}

# Build argv is capped at 4096 arguments.
expect {
	var $argv = ["cmd"]
	while $argv.len() <= 4096 {
		$argv = $argv.append("")
	}
	Project.validate(build_fixture([{ ..library, run: $argv }])).is_err()
}

# Build argv is capped at 1 MiB of argument bytes.
expect {
	var $argument = "x"
	while $argument.to_utf8().len() < 1048576 {
		$argument = $argument.concat($argument)
	}
	Project.validate(
		build_fixture([{ ..library, run: ["cmd", $argument] }]),
	).is_err()
}

# Build source declarations share the 1024 declaration cap.
expect {
	build_sources = chain_fixture(1025).map(
		|build| { name: build.name, ref: "path:./assets" },
	)
	Project.validate(
		build_source_fixture(build_sources, ["sources", "builds"]),
	) == Err("builds or build sources exceed 1024 declarations")
}

# Public workflow fixtures include both atomic kinds and a dotted task name.
workflow_fixture : List(Model.Workflow) -> Model
workflow_fixture = |workflows| workflow_features(workflows, ["workflows"])

workflow_features : List(Model.Workflow), List(Str) -> Model
workflow_features = |workflows, features| Model.{
	format: Model.current_format,
	name: "workflow tests",
	requires_: ["sources", "builds"].concat(features),
	systems: ["x86_64-linux"],
	sources: [],
	guix_channels: [],
	inputs: [],
	follows: [],
	environments: [
		{
			name: "builder",
			parents: [],
			tools: [],
			overlays: [],
			env: [],
			pure: Bool.False,
			aliases: [],
			rust_toolchain: None,
			package_env: [],
			on_systems: [],
		},
	],
	shells: [],
	tasks: [
		{
			name: "check.all",
			environment: "builder",
			run: ["cmd"],
			env: [],
			secrets: [],
			optional_environment_variables: [],
			needs: [],
			description: "",
			dir: "",
		},
	],
	build_sources: [{ name: "assets", ref: "path:./assets" }],
	fetches: [],
	cargo_vendors: [],
	build_root: "",
	builds: [library],
	workflows,
	extensions: [],
	raw: [],
}

# Flat steps keep literal extras separate from configured task argv.
expect {
	argv = ["", "two words", "\"quoted\"", "$HOME", "line\nbreak", "--flag"]
	leaf = { name: "leaf", description: "", steps: [RunTask("check.all", argv)] }
	model = workflow_fixture([
		{
			name: "ci",
			description: "",
			steps: [
				RunWorkflow("leaf"),
				BuildArtifact("library"),
				RunWorkflow("leaf"),
				BuildArtifact("library"),
			],
		},
		leaf,
	])
	Project.workflow_steps(model, "ci") == Ok([
		RunTask("check.all", argv),
		BuildArtifact("library"),
		RunTask("check.all", argv),
		BuildArtifact("library"),
	])
}

# Forward references and shared diamonds retain declaration order/repetitions.
expect {
	model = workflow_fixture([
		{
			name: "root",
			description: "",
			steps: [RunWorkflow("left"), RunWorkflow("right")],
		},
		{
			name: "right",
			description: "",
			steps: [BuildArtifact("library"), RunWorkflow("leaf")],
		},
		{
			name: "left",
			description: "",
			steps: [RunWorkflow("leaf"), RunTask("check.all", ["L"])],
		},
		{ name: "leaf", description: "", steps: [RunTask("check.all", ["shared"])] },
	])
	Project.workflow_steps(model, "root") == Ok([
		RunTask("check.all", ["shared"]),
		RunTask("check.all", ["L"]),
		BuildArtifact("library"),
		RunTask("check.all", ["shared"]),
	])
}

# All workflow tags and unusual argument bytes survive semantic normalization.
expect {
	model = workflow_fixture([
		{
			name: "ci",
			description: "",
			steps: [RunWorkflow("leaf"), BuildArtifact("library")],
		},
		{
			name: "leaf",
			description: "",
			steps: [RunTask("check.all", ["", "\n", "é"])],
		},
	])
	match Project.validate(model) {
		Ok(project) => Project.validate(project) == Ok(project)
		Err(_) => False
	}
}

# Empty workflows are valid no-ops, not missing requests.
expect Project.workflow_steps(
	workflow_fixture([
		{ name: "empty", description: "", steps: [] },
	]),
	"empty",
) == Ok([])

# A missing workflow must be an explicit failure, including on empty projects.
expect Project.workflow_steps(workflow_fixture([]), "missing") ==
	Err("unknown workflow: missing")

# Runtime model receives the same workflow-name checks as typed quotes.
expect Project.validate(
	workflow_fixture([
		{ name: "bad/name", description: "", steps: [] },
	]),
) == Err("invalid name for Workflow: bad/name")

# Duplicate workflow identities cannot silently choose the first declaration.
expect Project.validate(
	workflow_fixture([
		{ name: "ci", description: "", steps: [] },
		{ name: "ci", description: "", steps: [] },
	]),
) == Err("DuplicateWorkflow: ci")

# Populated optional workflow data always requires its capability marker.
expect Project.validate(
	workflow_features(
		[
			{ name: "ci", description: "", steps: [] },
		],
		[],
	),
) == Err("workflows require feature: workflows")

# Each reference kind has its own namespace; no command parsing or guessing.
expect [
	RunTask("library", []),
	BuildArtifact("check.all"),
	RunWorkflow("check.all"),
].all(
	|step|
		Project.validate(
			workflow_fixture([
				{
					name: "ci",
					description: "",
					steps: [step],
				},
			]),
		).is_err(),
)

# Direct cycles fail at the shared boundary before any expansion.
expect Project.validate(
	workflow_fixture([
		{ name: "ci", description: "", steps: [RunWorkflow("ci")] },
	]),
) == Err("workflow cycle: ci -> ci")

# Even an unused indirect cycle invalidates a requested valid workflow.
expect Project.workflow_steps(
	workflow_fixture([
		{ name: "safe", description: "", steps: [RunTask("check.all", [])] },
		{ name: "a", description: "", steps: [RunWorkflow("b")] },
		{ name: "b", description: "", steps: [RunWorkflow("a")] },
	]),
	"safe",
) == Err("workflow cycle: a -> b -> a")

# Unused unknown references also invalidate an otherwise valid request.
expect Project.workflow_steps(
	workflow_fixture([
		{ name: "safe", description: "", steps: [] },
		{ name: "broken", description: "", steps: [RunTask("absent", [])] },
	]),
	"safe",
) == Err("unknown task: absent")

# Workflow extras may be empty strings, but never contain a NUL byte.
expect Project.validate(
	workflow_fixture([
		{
			name: "ci",
			description: "",
			steps: [RunTask("check.all", [Str.from_utf8([0]) ?? ""])],
		},
	]),
) == Err("NUL in argv: check.all")

# Count configured argv together with extras, so a caller cannot bypass limits.
expect {
	var $argv = []
	while $argv.len() < 4096 {
		$argv = $argv.append("")
	}
	Project.validate(
		workflow_fixture([
			{ name: "ci", description: "", steps: [RunTask("check.all", $argv)] },
		]),
	).is_err()
}

# Graph fixtures can stress depth or doubling without huge source literals.
workflow_chain : U64, Bool, List(Model.WorkflowStep) -> List(Model.Workflow)
workflow_chain = |count, double, leaf| {
	var $workflows = []
	var $index = 0.U64
	while $index < count {
		steps = if ($index == 0) leaf else {
			step = RunWorkflow(($index - 1).to_str())
			if (double) [step, step] else [step]
		}
		$workflows = $workflows.append({
			name: $index.to_str(),
			description: "",
			steps,
		})
		$index = $index + 1
	}
	$workflows
}

# A legal 128-level empty diamond must not perform exponential expansion.
expect Project.workflow_steps(
	workflow_fixture(workflow_chain(128, True, [])),
	"127",
) == Ok([])

# Empty subgraphs interleaved with atomic steps cannot erase those effects.
expect {
	workflows = workflow_chain(120, True, []).append({
		name: "mixed",
		description: "",
		steps: [
			RunWorkflow("119"),
			RunTask("check.all", []),
			RunWorkflow("119"),
			BuildArtifact("library"),
		],
	})
	Project.workflow_steps(workflow_fixture(workflows), "mixed") ==
		Ok([RunTask("check.all", []), BuildArtifact("library")])
}

# Productive expansion is valid at the exact depth boundary too.
expect {
	workflows = workflow_chain(128, False, [RunTask("check.all", [])])
	Project.workflow_steps(workflow_fixture(workflows), "127") ==
		Ok([RunTask("check.all", [])])
}

# Cached heights must not hide excessive depth in declaration-order traversal.
expect Project.validate(workflow_fixture(workflow_chain(129, False, []))) ==
	Err("workflow dependencies exceed 128 levels")

# Reverse declaration order exercises the active-stack depth bound as well.
expect Project.validate(
	workflow_fixture(
		workflow_chain(129, False, [])
			.fold([], |acc, workflow| [workflow].concat(acc)),
	),
) ==
	Err("workflow dependencies exceed 128 levels")

# A compact shared DAG at the exact expansion limit retains all repetitions.
expect match Project.workflow_steps(
	workflow_fixture(workflow_chain(13, True, [RunTask("check.all", [])])),
	"12",
) {
	Ok(steps) => steps.len() == 4096 and
		steps.all(|step| step == RunTask("check.all", []))
	Err(_) => False
}

# Exponential nonempty DAGs are rejected by counts before allocating output.
expect Project.validate(
	workflow_fixture(workflow_chain(14, True, [RunTask("check.all", [])])),
) ==
	Err("workflow expansion exceeds 4096 atomic steps")

# Bounds apply to unrequested workflows as well, including empty declarations.
expect Project.validate(workflow_fixture(workflow_chain(1025, False, []))) ==
	Err("workflows exceed 1024 declarations")

# The total declared-step budget bounds wide graphs independently of depth.
expect {
	var $steps = []
	while $steps.len() <= 8192 {
		$steps = $steps.append(RunWorkflow("empty"))
	}
	Project.validate(
		workflow_fixture([
			{ name: "empty", description: "", steps: [] },
			{ name: "wide", description: "", steps: $steps },
		]),
	) == Err("workflow graph exceeds 8192 steps")
}

# Repetition has an argv-byte budget independent of the atomic-step count.
expect {
	var $arg = "x"
	while $arg.to_utf8().len() < 524288 {
		$arg = $arg.concat($arg)
	}
	Project.validate(
		workflow_fixture([
			{ name: "leaf", description: "", steps: [RunTask("check.all", [$arg])] },
			{
				name: "twice",
				description: "",
				steps: [RunWorkflow("leaf"), RunWorkflow("leaf")],
			},
		]),
	) == Err("workflow expansion exceeds 1 MiB argv bytes")
}

# A child's Env and PackageEnv override its parent's variables by name, either
# way. One environment may not set a variable with both, and Guix refuses
# PackageEnv.
expect {
	zlib = { source: "default", name: "zlib" }
	libraries = { name: "LIBS", value: LibraryPath([zlib]) }
	git = { source: "default", name: "git" }
	git_path = { name: "A", value: PackagePath(git) }
	parent = {
		..base,
		overlays: [],
		env: [{ name: "A", value: "1" }],
		package_env: [libraries],
	}
	dev = {
		..child,
		overlays: [],
		env: [{ name: "LIBS", value: "/x" }],
		package_env: [git_path],
	}
	resolved = match Project.validate(fixture([parent, dev])) {
		Ok(model) => model.environments.keep_if(|e| e.name == "dev")
			.map(|e| (e.env, e.package_env))
		Err(_) => []
	}
	both = { ..parent, env: [{ name: "LIBS", value: "/x" }] }
	resolved == [([{ name: "LIBS", value: "/x" }], [git_path])]
		and Project.validate(fixture([both]))
			== Err("Env and PackageEnv both set LIBS in environment base")
		and Project.check_environment(fixture([parent]), Guix, "base")
			== Err("PackageEnv needs Nix: environment base")
		and Project.check_environment(fixture([parent]), Nix, "base") == Ok({})
}

# CargoVendor takes git sources pinned by the commit Cargo.lock records.
expect {
	commit = "02237f8751db162e9ed0f5bd3e7135d1b256822e"
	source = "source = \"git+https://github.com/dtolnay/ryu?tag=1.0.20"
	vendor = |lock| Project.validate({
		..fixture([]),
		requires_: ["cargo"],
		cargo_vendors: [{ name: "crates", lock }],
	})
	vendor("${source}#${commit}\"\n").is_ok()
		and vendor("  ${source}#${commit}\"").is_ok()
		and vendor("${source}\"")
			== Err("CargoVendor crates: a git source names no commit")
		and vendor("${source}#${commit.drop_suffix("e")}\"").is_err()
}

# A BuildRoot names an ancestor with .. segments only, below the filesystem
# root.
expect {
	model = |build_root| { ..fixture([base]), build_root }
	root = |build_root| Project.snapshot_root(model(build_root), "/repo/apps/web")
	root("") == Ok("/repo/apps/web")
		and root("..") == Ok("/repo/apps")
		and root("../..") == Ok("/repo")
		and root("../../..").is_err()
		and Project.validate(model("../..")).is_ok()
		and ["../apps", "/repo", ".", "../", "..//.."].all(
			|bad|
				Project.validate(model(bad))
					== Err("invalid BuildRoot: ${bad}: use only .. segments"),
		)
}

# A task with a Dir runs through env --chdir; Dir stays inside the project.
expect {
	variables = [{ name: "A", value: "1" }]
	task = {
		name: "test",
		environment: "base",
		run: ["true"],
		env: [],
		secrets: [],
		optional_environment_variables: [],
		needs: [],
		description: "",
		dir: "apps/web",
	}
	in_dir = |dir|
		Project.validate({ ..fixture([base]), tasks: [{ ..task, dir }] })
	Project.env_command("apps/web", variables)
		== ["env", "--chdir=apps/web", "A=1"]
		and Project.env_command("", variables) == ["env", "A=1"]
		and Project.env_command("", []) == []
		and in_dir("apps/web").is_ok()
		and in_dir("").is_ok()
		and ["../web", "/abs", "apps/../..", "."].all(
			|dir| in_dir(dir) == Err("invalid Dir in task test: ${dir}"),
		)
}

# OnSystems adds tools and variables on its systems only, after and over the
# environment's own; a child's own variables override its parent's on every
# system. It names only declared systems.
expect {
	wayland = { source: "default", name: "wayland" }
	on = |name, value| {
		systems: ["x86_64-linux"],
		tools: [wayland],
		env: [{ name, value }],
	}
	parent = {
		..base,
		env: [{ name: "A", value: "base" }],
		on_systems: [on("A", "linux")],
	}
	env_on = |dev, system|
		match Project.validate(fixture([parent, dev])) {
			Ok(model) =>
				model.environments.keep_if(|e| e.name == "dev")
					.map(|e| Project.on_system(e, system).env)
			Err(_) => []
		}
	own = { ..child, env: [{ name: "B", value: "dev" }] }
	overriding = { ..child, env: [{ name: "A", value: "dev" }] }
	undeclared = {
		..child,
		on_systems: [{ ..on("B", "x"), systems: ["aarch64-darwin"] }],
	}
	Project.on_system(parent, "x86_64-linux").tools == base.tools.append(wayland)
		and Project.on_system(parent, "aarch64-linux").tools == base.tools
		and env_on(own, "x86_64-linux")
			== [[{ name: "B", value: "dev" }, { name: "A", value: "linux" }]]
		and env_on(own, "aarch64-linux")
			== [[{ name: "A", value: "base" }, { name: "B", value: "dev" }]]
		and env_on(overriding, "x86_64-linux") == [[{ name: "A", value: "dev" }]]
		and Project.validate(fixture([parent, undeclared]))
			== Err("OnSystems in environment dev names undeclared system aarch64-darwin")
}
