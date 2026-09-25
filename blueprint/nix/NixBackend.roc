# Pure Nix rendering for validated, reusable environment closures.
import ir.Ir
import ir.Project
import ir.Value
import ir.Request
import ir.Layout
import ir.Plan
import Backend
import Locks
import "build-runner.py" as build_runner : Str

## Package names are native Nix attributes, never translated or filtered.
## Each environment imports its sources with only its ordered overlay stack.
## Shell aliases and task entries share those imports. Raw values remain data,
## not executable Nix; Custom extensions are deliberately unsupported.
## Raw supports Attrs at `flake` and `shell:<alias>`, ignores other backends,
## and rejects duplicate attributes or replacement of packages/devShells.
## Alias Raw does not leak into another alias or a task's environment entry.
NixBackend :: [].{
	backend : Backend
	backend = Backend.{
		name: "nix",
		features: ["raw", "sources", "builds", "workflows"],
		render: |ir| render(ir).map_ok(
			|contents| [{ path: "flake.nix", contents }],
		),
	}

	default_nixpkgs : Str
	default_nixpkgs = Locks.default_nixpkgs

	## Rendering supports these target shapes, not cross-compilation or a host
	## support claim. Nix itself rejects tools unavailable on a declared target.
	supported_systems : List(Str)
	supported_systems = [
		"x86_64-linux",
		"aarch64-linux",
		"x86_64-darwin",
		"aarch64-darwin",
	]

	## Reserved shell prefix keeps aliases distinct from task environment refs.
	environment_shell : Str -> Str
	environment_shell = |name| "blueprint-env-${name}"

	## Validate and select the request before a consumer reads lock authority.
	## Planning reuses this same selection and renderer, without CLI semantics.
	preflight : Ir, Request, Str, Layout -> Try({}, Str)
	preflight = |ir, request, target, layout| {
		_ = prepare(ir, request, target, layout)?
		Ok({})
	}

	Prepared : {
		project : Ir,
		inputs : List(Locks.Input),
		builds : List(Ir.Build),
		argv : List(Str),
		contents : Str,
		action : [Generate, Shell(Str), Run(Str), Build(Str)],
	}

	## Expand only semantic requests. Every atomic request shares this selection
	## and renderer; never reload config or defer later capability/layout checks.
	prepare : Ir, Request, Str, Layout -> Try(List(Prepared), Str)
	prepare = |ir, request, target, layout| {
		project = Project.validate(ir)?
		match request {
			Request.Workflow(name) => {
				var $prepared = []
				var $templates = []
				var $bytes = 0.U64
				for step in Project.workflow_steps(project, name)? {
					atomic = match step {
						RunTask(task, extra) => Request.Run(task, extra)
						BuildArtifact(build) => Request.Build(build)
					}
					# Share immutable recipes, NEVER runtime artifacts or snapshots.
					# Repeated requests still append a complete executable step.
					selected = match $templates.find_first(|entry| entry.request == atomic) {
						Ok(entry) => entry.selected
						Err(_) => {
							fresh = prepare_atomic(
								project,
								atomic,
								target,
								layout,
								Limited(16777216 - $bytes),
							)?
							$bytes = $bytes + fresh.contents.to_utf8().len()
								+ fresh.argv.fold(0, |n, arg| n + arg.to_utf8().len())
							$templates = $templates.append({ request: atomic, selected: fresh })
							fresh
						}
					}
					$prepared = $prepared.append(selected)
				}
				# Empty workflows still check global features, declarations and layout.
				if $prepared.is_empty() {
					inputs = Locks.inputs(project)?
					_ = render_selected(
						project,
						[],
						[],
						"",
						Some({ inputs, layout }),
						Limited(16777216),
					)?
					check_layout(project, target, layout, False)?
				}
				return Ok($prepared)
			}
			_ => {}
		}
		Ok([prepare_atomic(project, request, target, layout, Unlimited)?])
	}

	## Structural validation belongs to prepare, before selecting any steps.
	prepare_atomic : Ir, Request, Str, Layout, RenderBudget -> Try(Prepared, Str)
	prepare_atomic = |project, request, target, layout, budget| {
		var $names = []
		var $builds = []
		var $argv = []
		var $action = Generate
		base_ref = "path:${layout.generated_root}"
		read_only = ["--no-update-lock-file", "--no-write-lock-file"]
		match request {
			Request.Generate => {
				$names = project.shells.map(|s| s.environment)
					.concat(project.tasks.map(|t| t.environment))
					.concat(project.builds.map(|b| b.environment))
				for build in project.builds {
					if !$builds.any(|selected| selected.name == build.name) {
						for dependency in Project.build_closure(project, build.name)? {
							if !$builds.any(|selected| selected.name == dependency.name) {
								$builds = $builds.append(dependency)
							}
						}
					}
				}
			}
			Request.Shell(name) => {
				$action = Shell(name)
				shell = project.shells.find_first(|s| s.name == name)
					.map_err(|_| "unknown shell: ${name}")?
				$names = [shell.environment]
				$argv = ["nix", "develop"].concat(read_only).append(
					"${base_ref}#devShells.${target}.${name}",
				)
			}
			Request.Run(name, extra) => {
				$action = Run(name)
				task = project.tasks.find_first(|t| t.name == name)
					.map_err(|_| "unknown task: ${name}")?
				command = task.run.concat(extra)
				Project.check_argv(command, name)?
				$names = [task.environment]
				entry = environment_shell(task.environment)
				$argv = ["nix", "develop"].concat(read_only)
					.concat(["${base_ref}#devShells.${target}.${entry}", "--command"])
					.concat(command)
			}
			Request.Build(name) => {
				$action = Build(name)
				if target != "x86_64-linux" {
					return Err("sandboxed builds currently require target x86_64-linux")
				}
				$builds = Project.build_closure(project, name)?
				$names = $builds.map(|b| b.environment)
				# Namespace witnesses compare caller/build on the same kernel.
				# Never dispatch this local isolation contract to a remote builder.
				$argv = ["nix", "build", "--no-link", "--print-out-paths"]
					.concat(read_only)
					.concat([
						"--builders",
						"",
						"--option",
						"sandbox",
						"true",
						"--option",
						"sandbox-fallback",
						"false",
						"--impure",
						"${base_ref}#packages.${target}.${name}",
					])
			}
			Request.Workflow(_) => return Err(
				"workflow must expand into atomic requests",
			)
		}
		inputs = Locks.inputs(project)?
		snapshot = "${layout.workspace}/snapshot"
		remaining = charge_rendered(
			budget,
			$argv.fold(0, |n, arg| n + arg.to_utf8().len()),
		)?
		contents = render_selected(
			project,
			$names,
			$builds,
			snapshot,
			Some({ inputs, layout }),
			remaining,
		)?
		check_layout(project, target, layout, !$builds.is_empty())?
		Ok({
			project,
			inputs,
			builds: $builds,
			argv: $argv,
			contents,
			action: $action,
		})
	}

	## Derive executable data only after complete structure, selected capability,
	## target, caller layout and authoritative lock checks. No effects occur here.
	plan : Ir, Request, Str, Layout, Locks -> Try(Plan, Str)
	plan = |ir, request, target, layout, locks| {
		prepared = prepare(ir, request, target, layout)?
		derived = Locks.derive(locks, Project.validate(ir)?, layout)?
		var $steps = []
		var $templates = []
		for selected in prepared {
			step = match $templates.find_first(
				|entry| entry.action == selected.action and entry.argv == selected.argv,
			) {
				Ok(entry) => entry
				Err(_) => {
					entry = materialize_plan(selected, target, layout, derived)
					$templates = $templates.append(entry)
					entry
				}
			}
			$steps = $steps.append(step)
		}
		Ok(Plan.{ steps: $steps })
	}

	## A snapshot operation belongs to one explicit build, never an artifact name.
	## Recheck supplied local pins on every step, including after source-editing
	## tasks.
	materialize_plan = |selected, target, layout, derived| {
		{ inputs, builds, argv, contents, action, .. } = selected
		snapshot = "${layout.workspace}/snapshot"
		base_ref = "path:${layout.generated_root}"
		var $operations = derived.operations
		match action {
			Build(_) => {
				local = inputs.keep_if(|i| i.ref.starts_with("path:"))
					.map(|i| "${layout.project_root}/${Locks.local_path(i)}")
				exclude = [
					".git",
					".hg",
					".svn",
					".jj",
					layout.workspace,
					layout.generated_root,
					layout.lock_path,
				]
					.concat(local)
				$operations = $operations.append(
					Snapshot({
						root: layout.project_root,
						destination: snapshot,
						exclude,
					}),
				)
			}
			_ => {}
		}
		files = staged_files(layout, contents, !builds.is_empty())
			.append({
				path: "${layout.generated_root}/flake.lock",
				contents: derived.contents,
			})
		{
			action,
			files,
			argv,
			operations: $operations,
			artifacts: builds.map(
				|build| {
					name: build.name,
					installable: "${base_ref}#packages.${target}.${build.name}",
					output: build.output,
					dependencies: build.needs,
				},
			),
		}
	}

	## Update consumers check these source roots before staging or fetching.
	## Keep provider/input path interpretation here, not duplicated in the CLI.
	local_checks : Ir, Str, Layout -> Try(List(Str), Str)
	local_checks = |ir, target, layout| {
		project = Project.validate(ir)?
		check_layout(project, target, layout, !project.builds.is_empty())?
		Ok(
			Locks.inputs(project)?
				.keep_if(|input| input.ref.starts_with("path:"))
				.map(|input| "${layout.project_root}/${Locks.local_path(input)}"),
		)
	}

	## Update renders the stable declarations but does not create authority.
	## The caller runs Nix explicitly, then validates with Locks.from_nix.
	update_files : Ir, Str, Layout -> Try(List(Plan.File), Str)
	update_files = |ir, target, layout| {
		project = Project.validate(ir)?
		check_layout(project, target, layout, !project.builds.is_empty())?
		inputs = Locks.inputs(project)?
		names = project.shells.map(|s| s.environment)
			.concat(project.tasks.map(|t| t.environment))
			.concat(project.builds.map(|b| b.environment))
		contents = render_selected(
			project,
			names,
			project.builds,
			"${layout.workspace}/snapshot",
			Some({ inputs, layout }),
			Unlimited,
		)?
		Ok(staged_files(layout, contents, !project.builds.is_empty()))
	}

	staged_files : Layout, Str, Bool -> List(Plan.File)
	staged_files = |layout, contents, builds| {
		files = [{ path: "${layout.generated_root}/flake.nix", contents }]
		if builds files.append({
			path: "${layout.generated_root}/build-runner.py",
			contents: build_runner,
		}) else files
	}

	check_layout : Ir, Str, Layout, Bool -> Try({}, Str)
	check_layout = |project, target, layout, builds| {
		Layout.validate(layout)?
		if !project.systems.contains(target) {
			return Err("target ${target} is not declared by the project")
		}
		snapshot = "${layout.workspace}/snapshot"
		isolation = "${snapshot}.isolation.json"
		# A generated directory may contain the workspace, but an actual file
		# must never become its ancestor (Snapshot would create it as a dir).
		files = staged_files(layout, "", builds).map(|file| file.path)
			.append("${layout.generated_root}/flake.lock")
		for file in files {
			if Layout.contains(file, layout.workspace)
				or [snapshot, isolation, layout.lock_path].any(
					|path| Layout.contains(file, path) or Layout.contains(path, file),
				) {
				return Err("generated files, snapshot and authority must not overlap")
			}
		}
		if Layout.contains(isolation, layout.generated_root)
			or Layout.contains(isolation, layout.lock_path)
				or Layout.contains(snapshot, layout.generated_root)
					or Layout.contains(snapshot, layout.lock_path)
						or Layout.contains(layout.generated_root, layout.lock_path) {
			return Err("generated files, snapshot and authority must not overlap")
		}
		for input in Locks.inputs(project)? {
			if input.ref.starts_with("path:") {
				path = "${layout.project_root}/${Locks.local_path(input)}"
				if Layout.contains(path, layout.workspace)
					or Layout.contains(layout.workspace, path)
						or Layout.contains(path, layout.generated_root)
							or Layout.contains(layout.generated_root, path)
								or Layout.contains(path, layout.lock_path) {
					return Err("local input overlaps caller-generated paths or lock")
				}
			}
		}
		Ok({})
	}

	## Whole rendering checks environments used by shells, tasks or builds.
	## Whole-project structural validation still rejects malformed declarations.
	render : Ir -> Try(Str, Str)
	render = |ir| {
		project = Project.validate(ir)?
		_ = Locks.inputs(project)?
		names = project.shells.map(|s| s.environment)
			.concat(project.tasks.map(|t| t.environment))
			.concat(project.builds.map(|b| b.environment))
		render_selected(project, names, project.builds, "", None, Unlimited)
	}

	## A Shell/Run consumer selects one environment before staging any effects.
	## Unrelated provider constraints must not block this request.
	render_environment : Ir, Str -> Try(Str, Str)
	render_environment = |ir, name| {
		project = Project.validate(ir)?
		_ = Locks.inputs(project)?
		render_closure(project, [name])
	}

	render_closure : Ir, List(Str) -> Try(Str, Str)
	render_closure = |ir, names|
		render_selected(ir, names, [], "", None, Unlimited)

	## Charge exact emitted UTF-8 bytes before retaining a renderer chunk.
	## Unlimited keeps standalone/inspection rendering on this same code path.
	RenderBudget : [Unlimited, Limited(U64)]

	charge_rendered : RenderBudget, U64 -> Try(RenderBudget, Str)
	charge_rendered = |budget, bytes| match budget {
		Unlimited => Ok(Unlimited)
		Limited(remaining) => if bytes > remaining {
			Err("workflow plan exceeds 16 MiB of distinct rendered requests")
		} else Ok(Limited(remaining - bytes))
	}

	## Accepted chunks stay within the remaining workflow text allowance.
	Rendered : { chunks : List(Str), budget : RenderBudget }

	## Never join a closure/system before checking its individual definitions.
	append_rendered : Rendered, Str -> Try(Rendered, Str)
	append_rendered = |rendered, chunk| {
		budget = charge_rendered(rendered.budget, chunk.to_utf8().len())?
		Ok({ chunks: rendered.chunks.append(chunk), budget })
	}

	## Inspection and executable plans share one renderer. Plans supply the full
	## stable input set and explicit snapshot path; inspection never guesses one.
	render_selected : Ir,
	List(Str),
	List(Ir.Build),
	Str,
	[
		None,
		Some({ inputs : List(Locks.Input), layout : Layout }),
	],
	RenderBudget -> Try(Str, Str)
	render_selected = |ir, names, builds, snapshot, staging, budget| {
		missing = ir.unsupported_features(backend.features)
		if !missing.is_empty() {
			return Err("unsupported features: ${Str.join_with(missing, ", ")}")
		}
		if !ir.extensions.is_empty() {
			kinds = ir.extensions.map(|e| "'${e.kind}' (${e.name})")
			return Err(
				"this blueprint does not support extensions yet; "
					.concat("Blueprint.roc uses ${Str.join_with(kinds, ", ")}"),
			)
		}
		for system in ir.systems {
			if !supported_systems.contains(system) {
				return Err("unsupported Nix target ${system}")
			}
		}
		selected_names = names.fold(
			[],
			|seen, name| if seen.contains(name) seen else seen.append(name),
		)
		for name in selected_names {
			Project.check_environment(ir, Nix, name)?
		}
		environments = ir.environments.keep_if(|e| names.contains(e.name))
		shells = ir.shells.keep_if(|s| names.contains(s.environment))
		# Validate all Raw declarations, even aliases outside this request.
		# Only selected aliases are emitted; flake-level data is always retained.
		var $shell_raw = []
		var $flake_raw = []
		for r in ir.raw.keep_if(|r| r.backend == "nix") {
			if r.target == "flake" {
				$flake_raw = $flake_raw.concat(raw_attrs(r)?)
			} else if r.target.starts_with("shell:") {
				name = r.target.drop_prefix("shell:")
				if !ir.shells.any(|s| s.name == name) {
					return Err("raw nix target \"${r.target}\" names no shell")
				}
				$shell_raw = $shell_raw.concat(
					raw_attrs(r)?.map(|a| { shell: name, attr: a }),
				)
			} else {
				return Err(
					"unknown raw nix target \"${r.target}\"; "
						.concat("expected \"flake\" or \"shell:<name>\""),
				)
			}
		}
		check_attr_names(
			"the raw flake outputs",
			$flake_raw.map(|a| a.name),
			["devShells", "packages"],
		)?
		for shell in ir.shells {
			if shell.name.starts_with("blueprint-env-") {
				return Err("shell prefix blueprint-env- is reserved")
			}
			extra = $shell_raw.keep_if(|x| x.shell == shell.name)
				.map(|x| x.attr)
			check_attr_names(
				"the raw attributes of shell \"${shell.name}\"",
				extra.map(|a| a.name),
				["packages"],
			)?
		}
		var $rendered = { chunks: [], budget }
		$rendered = append_rendered(
			$rendered,
			lines([
				"# Generated by blueprint from Blueprint.roc. Do not edit.",
				"{",
				"  description = ${quote("Development environments for ${ir.name}")};",
				"",
				"  inputs = {",
			]),
		)?
		# Inspection retains scoped inputs; plans emit stable full declarations.
		match staging {
			None => {
				for source in ir.sources.keep_if(
					|s| environments.any(|e| source_names(e).contains(s.name)),
				) {
					url = match source.provider {
						Auto => default_nixpkgs
						NixPackages(ref) => ref
						GuixPackages(_) => return Err("Nix cannot use Guix source ${source.name}")
					}
					$rendered = append_rendered(
						$rendered,
						"    ${quote(source.name)}.url = ${quote(url)};\n",
					)?
				}
				for input in ir.inputs.keep_if(
					|i| i.kind == Flake
						or environments.any(|e| e.overlays.contains(i.name)),
				) {
					$rendered = append_rendered(
						$rendered,
						"    ${quote(input.name)}.url = ${quote(input.url)};\n",
					)?
				}
				for source in ir.build_sources {
					$rendered = append_rendered(
						$rendered,
						"    ${quote(source.name)} = { url = ${quote(source.ref)}; "
							.concat("flake = false; };\n"),
					)?
				}
			}
			Some(data) => {
				for input in data.inputs {
					url = quote(Locks.input_url(input, data.layout))
					flake = if input.flake "true" else "false"
					$rendered = append_rendered(
						$rendered,
						"    ${quote(input.name)} = { url = ${url}; "
							.concat("flake = ${flake}; };\n"),
					)?
				}
			}
		}
		$rendered = append_rendered(
			$rendered,
			lines([
				"  };",
				"",
				"  outputs = { self, ... }@inputs:",
				"    let",
				"      environmentsFor = system: {",
			]),
		)?
		for environment in environments {
			$rendered = append_rendered(
				$rendered,
				render_environment_definition(environment),
			)?
		}
		$rendered = append_rendered(
			$rendered,
			lines([
				"      };",
				"    in",
				"    {",
				"      devShells = {",
			]),
		)?
		for system in ir.systems {
			$rendered = append_rendered(
				$rendered,
				lines([
					"        ${quote(system)} = let",
					"          environments = environmentsFor ${quote(system)};",
					"        in {",
				]),
			)?
			for environment in environments {
				$rendered = append_rendered(
					$rendered,
					"          ${quote(environment_shell(environment.name))} = "
						.concat("environments.${quote(environment.name)} { };\n"),
				)?
			}
			for shell in shells {
				extra = $shell_raw.keep_if(|x| x.shell == shell.name)
					.map(|x| x.attr)
				$rendered = append_rendered(
					$rendered,
					"          ${quote(shell.name)} = "
						.concat("environments.${quote(shell.environment)} ")
						.concat("${value_to_nix(Value.Attrs(extra))};\n"),
				)?
			}
			$rendered = append_rendered($rendered, "        };\n")?
		}
		$rendered = append_rendered($rendered, "      };\n")?
		if !builds.is_empty() {
			$rendered = append_rendered($rendered, "      packages = {\n")?
			for system in ir.systems {
				$rendered = append_rendered(
					$rendered,
					"        ${quote(system)} = let artifacts = {\n",
				)?
				for build in builds {
					env = environments.find_first(|e| e.name == build.environment)
						.map_err(|_| "unknown build environment")?
					$rendered = append_rendered(
						$rendered,
						render_build(build, env, system, snapshot),
					)?
				}
				$rendered = append_rendered(
					$rendered,
					"        }; in artifacts;\n",
				)?
			}
			$rendered = append_rendered($rendered, "      };\n")?
		}
		for attr in $flake_raw {
			$rendered = append_rendered(
				$rendered,
				"      ${quote(attr.name)} = ${value_to_nix(attr.value)};\n",
			)?
		}
		$rendered = append_rendered($rendered, lines(["    };", "}"]))?
		Ok(Str.join_with($rendered.chunks, ""))
	}

	## mkShell comes from the first tool's source, keeping unrelated providers
	## outside the request. Empty environments use the default source instead.
	source_names : Ir.Environment -> List(Str)
	source_names = |environment| {
		if environment.tools.is_empty() {
			return ["default"]
		}
		environment.tools.map(|t| t.source).fold(
			[],
			|seen, name|
				if seen.contains(name) seen else seen.append(name),
		)
	}

	render_environment_definition : Ir.Environment -> Str
	render_environment_definition = |environment| {
		sources = source_names(environment)
		primary = sources.first() ?? "default"
		overlays = environment.overlays.map(
			|name| "inputs.${quote(name)}.overlays.default",
		)
		set_lines = sources.map(
			|name|
				"            ${quote(name)} = import inputs.${quote(name)} "
					.concat("{ inherit system overlays; };"),
		)
		tools = environment.tools.map(
			|tool|
				"            sets.${quote(tool.source)}."
					.concat(attr_path(tool.name.split_on("."))),
		)
		lines([
			"        ${quote(environment.name)} = let",
			"          overlays = [ ${Str.join_with(overlays, " ")} ];",
			"          sets = {",
		]).concat(lines(set_lines)).concat(
			lines([
				"          };",
				"        in extra: sets.${quote(primary)}.mkShell ({",
				"          packages = [",
			]),
		).concat(lines(tools)).concat(
			lines([
				"          ];",
				"        } // extra);",
			]),
		)
	}

	## Ordinary, non-fixed-output derivations keep fetching outside user Run.
	## Runner tool paths are explicit; argv and metadata enter through JSON.
	render_build : Ir.Build, Ir.Environment, Str, Str -> Str
	render_build = |build, environment, system, snapshot| {
		sources = source_names(environment)
		primary = sources.first() ?? "default"
		overlays = environment.overlays.map(
			|name| "inputs.${quote(name)}.overlays.default",
		)
		sets = sources.map(
			|name|
				"            ${quote(name)} = import inputs.${quote(name)} "
					.concat("{ inherit system overlays; };"),
		)
		tools = environment.tools.map(
			|tool|
				"sets.${quote(tool.source)}.${attr_path(tool.name.split_on("."))}",
		)
		inputs = build.inputs.map(
			|name|
				"{ name = ${quote(name)}; path = inputs.${quote(name)}; }",
		)
		dependencies = build.needs.map(
			|name|
				"{ name = ${quote(name)}; path = artifacts.${quote(name)}; }",
		)
		project = if snapshot.is_empty() {
			"builtins.throw \"build execution requires NixBackend.plan "
				.concat("and a caller snapshot\"")
		} else {
			"builtins.path { path = /. + ${quote(snapshot)}; "
				.concat("name = \"blueprint-project\"; }")
		}
		# Namespace observations belong to materialization, not project bytes.
		isolation = if snapshot.is_empty() {
			"builtins.throw \"build execution requires a caller isolation witness\""
		} else {
			"builtins.fromJSON (builtins.readFile "
				.concat("${quote("${snapshot}.isolation.json")})")
		}
		argv = Str.join_with(build.run.map(quote), " ")
		lines([
			"          ${quote(build.name)} = let",
			"            system = ${quote(system)};",
			"            overlays = [ ${Str.join_with(overlays, " ")} ];",
			"            sets = {",
		]).concat(lines(sets)).concat(
			lines([
				"            };",
				"            pkgs = sets.${quote(primary)};",
				"            tools = [ ${Str.join_with(tools, " ")} ];",
				"          in pkgs.runCommand ${quote("blueprint-${build.name}")} {",
				"            blueprintSpec = builtins.toJSON {",
				"              project = ${project};",
				"              isolation = ${isolation};",
				"              argv = [ ${argv} ];",
				"              output = ${quote(build.output)};",
				"              path = pkgs.lib.makeBinPath (tools ++ "
					.concat("[ pkgs.python3 pkgs.coreutils pkgs.bash ]);"),
				"              inputs = pkgs.linkFarm "
					.concat(quote("blueprint-inputs-${build.name}"))
					.concat(" [ ${Str.join_with(inputs, " ")} ];"),
				"              artifacts = pkgs.linkFarm "
					.concat(quote("blueprint-artifacts-${build.name}"))
					.concat(" [ ${Str.join_with(dependencies, " ")} ];"),
				"            };",
				"            passAsFile = [ \"blueprintSpec\" ];",
				"          } ''",
				"            \${pkgs.python3}/bin/python3 -I \${./build-runner.py} "
					.concat("\"$blueprintSpecPath\""),
				"          '';",
			]),
		)
	}

	raw_attrs : Ir.Raw -> Try(List({ name : Str, value : Value }), Str)
	raw_attrs = |r| match r.value {
		Attrs(attrs) => Ok(attrs)
		_ => Err("raw nix value for \"${r.target}\" must be Attrs")
	}

	check_attr_names : Str, List(Str), List(Str) -> Try({}, Str)
	check_attr_names = |what, names, reserved| {
		var $seen = []
		for name in names {
			if reserved.contains(name) {
				return Err("${what} set \"${name}\", which the Nix backend writes itself")
			}
			if $seen.contains(name) {
				return Err("${what} set \"${name}\" more than once")
			}
			$seen = $seen.append(name)
		}
		Ok({})
	}

	## Render data only; interpolation and quotes cannot inject expressions.
	value_to_nix : Value -> Str
	value_to_nix = |value| match value {
		Str(s) => quote(s)
		Int(n) => if n < 0 "(${n.to_str()})" else n.to_str()
		Bool(b) => if b "true" else "false"
		List([]) => "[ ]"
		List(items) => "[ ${Str.join_with(items.map(value_to_nix), " ")} ]"
		Attrs([]) => "{ }"
		Attrs(attrs) => {
			fields = attrs.map(|a| "${quote(a.name)} = ${value_to_nix(a.value)};")
			"{ ${Str.join_with(fields, " ")} }"
		}
	}

	attr_path : List(Str) -> Str
	attr_path = |path| Str.join_with(path.map(quote), ".")

	lines : List(Str) -> Str
	lines = |items| items.fold("", |acc, line| acc.concat(line).concat("\n"))

	quote : Str -> Str
	quote = |value| {
		escaped = value
			.replace_each("\\", "\\\\")
			.replace_each("\"", "\\\"")
			.replace_each("\${", "\\\${")
			.replace_each("\n", "\\n")
			.replace_each("\r", "\\r")
			.replace_each("\t", "\\t")
		"\"${escaped}\""
	}
}

import "tests/sample.ir.scm" as sample_wire : Str
import "tests/full.ir.scm" as full_wire : Str
import "tests/sample.golden.nix" as sample_golden : Str
import "tests/full.golden.nix" as full_golden : Str

# The simple fixture covers scoped overlays, dotted attributes and aliases.
expect Ir.parse(sample_wire).map_err(|_| "invalid fixture")
	.map_ok(NixBackend.render) == Ok(Ok(sample_golden))

# The full fixture covers multiple sources, task-only environments and Raw data.
expect Ir.parse(full_wire).map_err(|_| "invalid fixture")
	.map_ok(NixBackend.render) == Ok(Ok(full_golden))

# Quotes, interpolation and control characters stay literal data.
expect NixBackend.value_to_nix(Value.Str("a\"b\\c\${d}\n\r\t")) ==
	"\"a\\\"b\\\\c\\\${d}\\n\\r\\t\""

# Nested data and negative numbers remain valid Nix expressions.
expect NixBackend.value_to_nix(
	Value.List([
		Value.Int(1),
		Value.Int(-2),
		Value.Attrs([{ name: "a b", value: Value.List([Value.Bool(True)]) }]),
	]),
) == "[ 1 (-2) { \"a b\" = [ true ]; } ]"

# Empty aggregate data and booleans preserve their native Nix values.
expect [Value.List([]), Value.Attrs([]), Value.Bool(False)]
	.map(NixBackend.value_to_nix) == ["[ ]", "{ }", "false"]

# Ordinary dollars without interpolation need no escaping.
expect NixBackend.value_to_nix(Value.Str("$x \$ {y}")) == "\"$x \$ {y}\""

# Focused IR values exercise the public renderer without a CLI or effects.
TestIr : {
	systems : List(Str),
	sources : List(Ir.Source),
	inputs : List(Ir.Input),
	environments : List(Ir.Environment),
	shells : List(Ir.Shell),
	tasks : List(Ir.Task),
	requires_ : List(Str),
	raw : List(Ir.Raw),
	extensions : List(Ir.Extension),
}

base : Ir.Environment
base = { name: "dev", parents: [], tools: [], overlays: [] }

simple : TestIr
simple = {
	systems: ["x86_64-linux"],
	sources: [],
	inputs: [],
	environments: [base],
	shells: [{ name: "default", environment: "dev" }],
	tasks: [],
	requires_: [],
	raw: [],
	extensions: [],
}

mk : TestIr -> Ir
mk = |t| Ir.{
	format: Ir.current_format,
	name: "test",
	systems: t.systems,
	sources: t.sources,
	inputs: t.inputs,
	environments: t.environments,
	shells: t.shells,
	tasks: t.tasks,
	build_sources: [],
	builds: [],
	workflows: [],
	requires_: t.requires_,
	raw: t.raw,
	extensions: t.extensions,
}

rejects : TestIr, Str -> Bool
rejects = |t, fragment| match NixBackend.render(mk(t)) {
	Err(message) => message.contains(fragment)
	Ok(_) => False
}

foreign : Ir.Environment
foreign = {
	..base,
	name: "foreign",
	tools: [{ source: "guix", name: "python@3:out" }],
}

mixed : TestIr
mixed = {
	..simple,
	sources: [{ name: "guix", provider: GuixPackages("channels") }],
	environments: [base, foreign],
}

# An omitted package source supplies mkShell from the backend's default.
expect match NixBackend.render(mk(simple)) {
	Ok(text) => text.contains(
		"\"default\".url = \"github:NixOS/nixpkgs/nixos-unstable\";",
	)
	Err(_) => False
}

# Tasks need stable entries even when no alias refers to their environment.
expect match NixBackend.render(
	mk({
		..simple,
		shells: [],
		tasks: [{ name: "check", environment: "dev", run: ["git", "--version"] }],
	}),
) {
	Ok(text) => text.contains("\"blueprint-env-dev\" = environments.\"dev\"")
	Err(_) => False
}

# Unused Guix declarations must not block the project's Nix shell/task closure.
expect NixBackend.render(mk(mixed)).is_ok()

# Selecting the foreign environment fails instead of overriding its provider.
expect NixBackend.render_environment(mk(mixed), "foreign").is_err()

# A selected Nix environment works even when another shell needs Guix.
expect {
	project = mk({
		..mixed,
		shells: simple.shells.append({ name: "foreign", environment: "foreign" }),
	})
	NixBackend.render(project).is_err()
		and NixBackend.render_environment(project, "dev").is_ok()
}

# Inherited stacks stay ordered, deduplicated and scoped to the chosen env.
expect {
	parent = { ..base, name: "base", overlays: ["base"] }
	child = { ..base, parents: ["base"], overlays: ["base", "patch"] }
	stacked = {
		..simple,
		inputs: [
			{ name: "base", url: "github:example/base", kind: Overlay },
			{ name: "patch", url: "github:example/patch", kind: Overlay },
		],
		environments: [parent, child],
	}
	inherited = NixBackend.render_environment(mk(stacked), "dev")
	inline = NixBackend.render_environment(
		mk({
			..stacked,
			environments: [parent, { ..child, parents: [] }],
		}),
		"dev",
	)
	inherited == inline and match inherited {
		Ok(text) => text.contains(
			"overlays = [ inputs.\"base\".overlays.default "
				.concat("inputs.\"patch\".overlays.default ];"),
		)
		Err(_) => False
	} and match NixBackend.render_environment(mk(stacked), "base") {
		Ok(text) => !text.contains("inputs.\"patch\".overlays.default")
		Err(_) => False
	}
}

# Unknown requests fail before a caller can generate files or invoke Nix.
expect NixBackend.render_environment(mk(simple), "missing").is_err()

# All supported target shapes are explicit; unsupported declarations are errors.
expect NixBackend.render(
	mk({
		..simple,
		systems: NixBackend.supported_systems,
	}),
).is_ok() and rejects({ ..simple, systems: ["riscv64-linux"] }, "target")

# Native missing attributes survive rendering and fail later in Nix itself.
expect match NixBackend.render(
	mk({
		..simple,
		environments: [
			{
				..base,
				tools: [{ source: "default", name: "missingNativePackage" }],
			},
		],
	}),
) {
	Ok(text) => text.contains("sets.\"default\".\"missingNativePackage\"")
		and !text.contains("builtins.filter") and !text.contains("availableOn")
	Err(_) => False
}

# Auto tool syntax is checked for the selected provider before any effects.
expect NixBackend.render(
	mk({
		..simple,
		environments: [
			{
				..base,
				tools: [{ source: "default", name: "python@3:out" }],
			},
		],
	}),
).is_err()

# Native numeric-leading attributes are quoted, not rejected as identifiers.
expect match NixBackend.render(
	mk({
		..simple,
		environments: [{ ..base, tools: [{ source: "default", name: "7zip" }] }],
	}),
) {
	Ok(text) => text.contains("sets.\"default\".\"7zip\"")
	Err(_) => False
}

# Unknown capability requirements cannot disappear during direct rendering.
expect rejects({ ..simple, requires_: ["future-build"] }, "future-build")

# Unsupported Custom blocks retain the clear extension diagnostic.
expect rejects(
	{
		..simple,
		extensions: [{ kind: "service", name: "db", value: Value.Attrs([]) }],
	},
	"does not support extensions",
)

# Raw targeting another backend stays inert, regardless of its value shape.
expect NixBackend.render(
	mk({
		..simple,
		raw: [{ backend: "guix", target: "bogus", value: Value.Int(1) }],
	}),
).is_ok()

# Nix Raw targets must be either the flake or a declared shell alias.
expect rejects(
	{
		..simple,
		raw: [{ backend: "nix", target: "bogus", value: Value.Attrs([]) }],
	},
	"unknown raw nix target",
) and rejects(
	{
		..simple,
		raw: [{ backend: "nix", target: "shell:nope", value: Value.Attrs([]) }],
	},
	"names no shell",
)

# Shell Raw must be attribute data, not a string of Nix expressions.
expect rejects(
	{
		..simple,
		raw: [{ backend: "nix", target: "shell:default", value: Value.Str("x") }],
	},
	"must be Attrs",
)

# Raw cannot overwrite generated packages or flake devShells.
expect rejects(
	{
		..simple,
		raw: [
			{
				backend: "nix",
				target: "shell:default",
				value: Value.Attrs([
					{ name: "packages", value: Value.List([]) },
				]),
			},
		],
	},
	"set \"packages\"",
) and rejects(
	{
		..simple,
		raw: [
			{
				backend: "nix",
				target: "flake",
				value: Value.Attrs([
					{ name: "devShells", value: Value.Attrs([]) },
				]),
			},
		],
	},
	"set \"devShells\"",
)

# Duplicate Raw attributes across entries produce a diagnostic, not invalid Nix.
expect {
	raw = {
		backend: "nix",
		target: "shell:default",
		value: Value.Attrs([
			{ name: "FOO", value: Value.Str("bar") },
		]),
	}
	rejects({ ..simple, raw: [raw, raw] }, "more than once")
}

# Shell aliases cannot collide with stable task environment output names.
expect NixBackend.render(
	mk({
		..simple,
		shells: [{ name: "blueprint-env-dev", environment: "dev" }],
	}),
).is_err()

import TestData
import "tests/local.nix-lock.json" as native_lock : Str

plan_locks : Try(Locks, Str)
plan_locks = Locks.from_nix(
	TestData.project(TestData.data),
	TestData.layout,
	native_lock,
)

plan_fixture : Request -> Try(Plan, Str)
plan_fixture = |request| {
	locks = plan_locks?
	NixBackend.plan(
		TestData.project(TestData.data),
		request,
		"x86_64-linux",
		TestData.layout,
		locks,
	)
}

# Preflight rejects the same requested closures without needing lock data.
expect {
	project = mk({
		..mixed,
		shells: simple.shells.append({ name: "foreign", environment: "foreign" }),
	})
	NixBackend.preflight(
		project,
		Request.Shell("default"),
		"x86_64-linux",
		TestData.layout,
	).is_ok()
		and NixBackend.preflight(
			project,
			Request.Shell("foreign"),
			"x86_64-linux",
			TestData.layout,
		).is_err()
}

# Unsupported declarations take precedence over absent requested targets.
expect NixBackend.preflight(
	mk({ ..simple, systems: ["riscv64-linux"] }),
	Request.Shell("default"),
	"x86_64-linux",
	TestData.layout,
) == Err("unsupported Nix target riscv64-linux")

# A build plans dependency-first artifacts and exact, immutable sandbox argv.
expect match plan_fixture(Request.Build("app")) {
	Ok({ steps: [plan] }) => plan.action == Build("app") and plan.artifacts == [
		{
			name: "library",
			installable: "path:/generated#packages.x86_64-linux.library",
			output: "dist/library",
			dependencies: [],
		},
		{
			name: "app",
			installable: "path:/generated#packages.x86_64-linux.app",
			output: "dist/app",
			dependencies: ["library"],
		},
	] and plan.argv == [
		"nix",
		"build",
		"--no-link",
		"--print-out-paths",
		"--no-update-lock-file",
		"--no-write-lock-file",
		"--builders",
		"",
		"--option",
		"sandbox",
		"true",
		"--option",
		"sandbox-fallback",
		"false",
		"--impure",
		"path:/generated#packages.x86_64-linux.app",
	]
	_ => False
}

# Inputs are verified before each fresh snapshot, including every excluded root.
expect match plan_fixture(Request.Build("app")) {
	Ok({ steps: [plan] }) => plan.operations == [
		VerifyLocal({
			path: "/project/assets",
			nar_hash: "sha256-mhO52EWOvxHOyTFt0V1hM6Oo6mlpNo2PFlxQtcmCJBc=",
		}),
		Snapshot({
			root: "/project",
			destination: "/work/snapshot",
			exclude: [
				".git",
				".hg",
				".svn",
				".jj",
				"/work",
				"/generated",
				"/authority/inputs.lock",
				"/project/assets",
			],
		}),
	] and plan.files.map(|file| file.path) == [
		"/generated/flake.nix",
		"/generated/build-runner.py",
		"/generated/flake.lock",
	]
	_ => False
}

# User argv is data; source/dependency views are immutable store farms.
expect match plan_fixture(Request.Build("app")) {
	Ok({ steps: [plan] }) => match plan.files.first() {
		Ok(file) => file.contents.contains(
			"\"\" \"two words\" \"line\\nbreak\" \"$HOME\"",
		)
			and file.contents.contains("path = artifacts.\"library\";")
				and file.contents.contains("path = inputs.\"assets\";")
					and file.contents.contains("path = /. + \"/work/snapshot\";")
						and file.contents.contains(
							"builtins.readFile \"/work/snapshot.isolation.json\"",
						)
							and file.contents.contains("pkgs.runCommand")
								and !file.contents.contains("outputHash")
		Err(_) => False
	}
	_ => False
}

# Task extras preserve empty arguments, controls and option-looking literals.
expect match plan_fixture(
	Request.Run(
		"check",
		["", "two words", "--flag", "a\nb"],
	),
) {
	Ok({ steps: [plan] }) => plan.action == Run("check") and plan.argv == [
		"nix",
		"develop",
		"--no-update-lock-file",
		"--no-write-lock-file",
		"path:/generated#devShells.x86_64-linux.blueprint-env-builder",
		"--command",
		"python3",
		"check.py",
		"configured argument",
		"",
		"two words",
		"--flag",
		"a\nb",
	] and plan.artifacts.is_empty()
		and plan.operations.len() == 1 and plan.files.len() == 2
	_ => False
}

# Aliases use the caller target, never the host's implicit default output shape.
expect match plan_fixture(Request.Shell("default")) {
	Ok({ steps: [plan] }) => plan.action == Shell("default") and plan.argv == [
		"nix",
		"develop",
		"--no-update-lock-file",
		"--no-write-lock-file",
		"path:/generated#devShells.x86_64-linux.default",
	]
		and plan.artifacts.is_empty()
	_ => False
}

# Generate produces no backend command or snapshot and never writes authority.
expect match plan_fixture(Request.Generate) {
	Ok({ steps: [plan] }) => plan.action == Generate
		and plan.argv.is_empty() and plan.operations.len() == 1
			and !plan.files.any(|file| file.path == TestData.layout.lock_path)
	_ => False
}

# Generate orders all builds dependency-first, sharing dependencies once even
# when consumers precede them and more than one root needs the same library.
expect match plan_locks {
	Ok(locks) => {
		project = TestData.project({
			..TestData.data,
			builds: [
				TestData.application,
				{ ..TestData.application, name: "other" },
				TestData.library,
			],
		})
		match NixBackend.plan(
			project,
			Request.Generate,
			"x86_64-linux",
			TestData.layout,
			locks,
		) {
			Ok({ steps: [plan] }) =>
				plan.artifacts.map(|artifact| artifact.name) ==
					["library", "app", "other"]
					and plan.artifacts.map(|artifact| artifact.dependencies) ==
						[[], ["library"], ["library"]]
			_ => False
		}
	}
	Err(_) => False
}

# Request selection never shrinks root inputs or causes an implicit relock.
expect match (
	plan_fixture(Request.Build("library")),
	plan_fixture(Request.Shell("default")),
) {
	(Ok({ steps: [build] }), Ok({ steps: [shell] })) => {
		build_lock = build.files.find_first(|f| f.path == "/generated/flake.lock")
		shell_lock = shell.files.find_first(|f| f.path == "/generated/flake.lock")
		build_lock == shell_lock and match shell.files.first() {
			Ok(file) => file.contents.contains(
				"\"assets\" = { url = \"path:/project/assets\"; "
					.concat("flake = false; };"),
			)
			Err(_) => False
		}
	}
	_ => False
}

# Unknown requests and NUL task extras fail before producing any effect recipe.
expect [
	Request.Shell("missing"),
	Request.Run("missing", []),
	Request.Build("missing"),
	Request.Run("check", [Str.from_utf8([0]) ?? ""]),
]
	.all(|request| plan_fixture(request).is_err())

# Unsupported features, targets and selected providers reject before effects.
expect match plan_locks {
	Ok(locks) => {
		bad = [
			{ ..TestData.data, requires_: ["sources", "builds", "future"] },
			{ ..TestData.data, systems: ["x86_64-linux", "riscv64-linux"] },
			{
				..TestData.data,
				sources: [{ name: "default", provider: GuixPackages("channels") }],
			},
		]
		bad.all(
			|data| NixBackend.plan(
				TestData.project(data),
				Request.Build("app"),
				"x86_64-linux",
				TestData.layout,
				locks,
			).is_err(),
		)
	}
	Err(_) => False
}

# The dependency closure includes each builder's provider requirements.
expect {
	foreign_builder = {
		..TestData.builder,
		name: "foreign",
		tools: [{ source: "guix", name: "python@3:out" }],
	}
	data = {
		..TestData.data,
		sources: [{ name: "guix", provider: GuixPackages("channels") }],
		environments: [TestData.builder, foreign_builder],
		builds: [
			TestData.application,
			{ ..TestData.library, environment: "foreign" },
		],
	}
	project = TestData.project(data)
	match Locks.from_nix(project, TestData.layout, native_lock) {
		Ok(locks) => NixBackend.plan(
			project,
			Request.Shell("default"),
			"x86_64-linux",
			TestData.layout,
			locks,
		).is_ok()
			and NixBackend.plan(
				project,
				Request.Build("app"),
				"x86_64-linux",
				TestData.layout,
				locks,
			).is_err()
		Err(_) => False
	}
}

# Reordering declarations preserves authority identity; overlay order does not.
expect {
	url = Locks.default_nixpkgs
	data = {
		..TestData.data,
		inputs: [
			{ name: "first", url, kind: Overlay },
			{ name: "second", url, kind: Overlay },
		],
		environments: [
			{ ..TestData.builder, overlays: ["first", "second"] },
			{ ..TestData.builder, name: "other" },
		],
	}
	native = native_lock.replace_each(
		"\"default\": \"default\"",
		"\"default\": \"default\", \"first\": \"default\", \"second\": \"default\"",
	)
	project = TestData.project(data)
	match Locks.from_nix(project, TestData.layout, native) {
		Ok(locks) => {
			reordered = TestData.project({
				..data,
				inputs: [
					{ name: "second", url, kind: Overlay },
					{ name: "first", url, kind: Overlay },
				],
				environments: [
					{ ..TestData.builder, name: "other" },
					{ ..TestData.builder, overlays: ["first", "second"] },
				],
			})
			reversed = TestData.project({
				..data,
				environments: [
					{ ..TestData.builder, overlays: ["second", "first"] },
					{ ..TestData.builder, name: "other" },
				],
			})
			NixBackend.plan(
				reordered,
				Request.Build("app"),
				"x86_64-linux",
				TestData.layout,
				locks,
			).is_ok()
				and NixBackend.plan(
					reversed,
					Request.Build("app"),
					"x86_64-linux",
					TestData.layout,
					locks,
				).is_err()
		}
		Err(_) => False
	}
}

# Out-of-tree roots work; overlapping sources, authority or snapshots do not.
expect match plan_locks {
	Ok(locks) => {
		layouts = [
			Layout.{
				project_root: "/project",
				workspace: "/project/assets/work",
				generated_root: "/generated",
				lock_path: "/authority/lock",
			},
			Layout.{
				project_root: "/project",
				workspace: "/work",
				generated_root: "/work/snapshot/nix",
				lock_path: "/authority/lock",
			},
			Layout.{
				project_root: "/project",
				workspace: "/work",
				generated_root: "/generated",
				lock_path: "/generated/flake.lock",
			},
			Layout.{
				project_root: "/project",
				workspace: "/work",
				generated_root: "/generated",
				lock_path: "/work/snapshot.isolation.json",
			},
			Layout.{
				project_root: "/project",
				workspace: "/work/../unsafe",
				generated_root: "/generated",
				lock_path: "/authority/lock",
			},
		]
		layouts.all(
			|layout| NixBackend.plan(
				TestData.project(TestData.data),
				Request.Build("app"),
				"x86_64-linux",
				layout,
				locks,
			).is_err(),
		)
	}
	Err(_) => False
}

# File/directory conflicts fail in pure preflight and both update entry points,
# before lock reads, VerifyLocal, Snapshot or staging can have effects.
expect ["flake.nix", "flake.lock", "build-runner.py"].all(
	|file| {
		["", "/child"].all(
			|suffix| {
				layout = Layout.{
					project_root: "/project",
					workspace: "/generated/${file}${suffix}",
					generated_root: "/generated",
					lock_path: "/authority/inputs.lock",
				}
				project = TestData.project(TestData.data)
				NixBackend.preflight(
					project,
					Request.Build("app"),
					"x86_64-linux",
					layout,
				).is_err()
					and NixBackend.preflight(
						project,
						Request.Generate,
						"x86_64-linux",
						layout,
					).is_err()
						and NixBackend.local_checks(project, "x86_64-linux", layout).is_err()
							and NixBackend.update_files(project, "x86_64-linux", layout).is_err()
			},
		)
	},
)

# Containment alone is fine when the workspace does not collide with a file.
expect NixBackend.preflight(
	TestData.project(TestData.data),
	Request.Build("app"),
	"x86_64-linux",
	Layout.{
		project_root: "/project",
		workspace: "/generated/work",
		generated_root: "/generated",
		lock_path: "/authority/inputs.lock",
	},
).is_ok()

# Update exposes all local source paths for pre-effect consumer safety checks.
expect NixBackend.local_checks(
	TestData.project(TestData.data),
	"x86_64-linux",
	TestData.layout,
) == Ok(["/project/assets"])

# Explicit update files contain only derivatives, not a second lock authority.
expect match NixBackend.update_files(
	TestData.project(TestData.data),
	"x86_64-linux",
	TestData.layout,
) {
	Ok(files) => files.map(|file| file.path) == [
		"/generated/flake.nix",
		"/generated/build-runner.py",
	]
	Err(_) => False
}

# Shared workflow input uses the same supplied authority as atomic requests.
workflow_project : Ir
workflow_project = TestData.project(TestData.workflow_data)

workflow_plan : Request -> Try(Plan, Str)
workflow_plan = |request| NixBackend.plan(
	workflow_project,
	request,
	"x86_64-linux",
	TestData.layout,
	plan_locks?,
)

# The maximum repeated build sequence shares a large immutable recipe, not
# artifacts: all 4096 explicit operations still carry their own snapshot step.
expect {
	var $payload = "x"
	while $payload.to_utf8().len() < 524288 {
		$payload = $payload.concat($payload)
	}
	var $steps = [BuildArtifact("library")]
	while $steps.len() < 4096 {
		$steps = $steps.concat($steps)
	}
	project = TestData.project({
		..TestData.workflow_data,
		builds: [{ ..TestData.library, run: ["true", $payload] }],
		workflows: [{ name: "large", steps: $steps }],
	})
	plan = NixBackend.plan(
		project,
		Request.Workflow("large"),
		"x86_64-linux",
		TestData.layout,
		plan_locks?,
	)?
	plan.steps.len() == 4096 and plan.steps.all(
		|step| step.action == Build("library")
			and step.artifacts.map(|artifact| artifact.name) == ["library"]
				and step.operations.keep_if(
					|operation| match operation {
						Snapshot(_) => True
						VerifyLocal(_) => False
					},
				).len() == 1,
	) and match plan.steps.first() {
		Ok(step) => match step.files.first() {
			Ok(file) => file.contents.to_utf8().len() > 524288
			Err(_) => False
		}
		Err(_) => False
	}
}

# Sharing one task's templates must key on exact extras, including repetitions
# separated by different argv, empty strings, controls and literal shell text.
expect {
	extras = [
		["", "two words", "--literal", "a\nb", "$HOME"],
		["two", "words", "", "a\tb", "\\", "\""],
		[],
		["", "two words", "--literal", "a\nb", "$HOME"],
	]
	project = {
		..workflow_project,
		workflows: [
			{
				name: "argv",
				steps: extras.map(
					|extra| RunTask("check", extra),
				),
			},
		],
	}
	plan = NixBackend.plan(
		project,
		Request.Workflow("argv"),
		"x86_64-linux",
		TestData.layout,
		plan_locks?,
	)?
	prefix = [
		"nix",
		"develop",
		"--no-update-lock-file",
		"--no-write-lock-file",
		"path:/generated#devShells.x86_64-linux.blueprint-env-builder",
		"--command",
		"python3",
		"check.py",
		"configured argument",
	]
	plan.steps.map(|step| step.argv) == extras.map(|extra| prefix.concat(extra))
		and plan.steps.map(|step| step.action) == [
			Run("check"),
			Run("check"),
			Run("check"),
			Run("check"),
		]
}

# Distinct requests count all rendered systems toward the 16 MiB budget.
# Four valid near-1-MiB build argv render over budget; three remain below it.
expect {
	var $payload = "x"
	while $payload.to_utf8().len() < 1048576 {
		$payload = $payload.concat($payload)
	}
	names = ["one", "two", "three", "four"]
	project = TestData.project({
		..TestData.workflow_data,
		systems: NixBackend.supported_systems,
		builds: names.map(
			|name| {
				..TestData.library,
				name,
				run: ["x", $payload.drop_prefix("x")],
			},
		),
		workflows: [
			{
				name: "below",
				steps: [
					BuildArtifact("one"),
					BuildArtifact("two"),
					BuildArtifact("three"),
				],
			},
			{ name: "over", steps: names.map(|name| BuildArtifact(name)) },
		],
	})
	locks = plan_locks?
	below = NixBackend.plan(
		project,
		Request.Workflow("below"),
		"x86_64-linux",
		TestData.layout,
		locks,
	)?
	diagnostic = "workflow plan exceeds 16 MiB of distinct rendered requests"
	below.steps.len() == 3 and NixBackend.preflight(
		project,
		Request.Workflow("over"),
		"x86_64-linux",
		TestData.layout,
	) == Err(diagnostic) and NixBackend.plan(
		project,
		Request.Workflow("over"),
		"x86_64-linux",
		TestData.layout,
		locks,
	).map_ok(|plan| plan.steps) == Err(diagnostic)
}

# One valid atomic step can exceed the budget through its dependency closure.
# Reject during definition emission, not after assembling 126 MiB of argv.
expect {
	var $payload = "x"
	while $payload.to_utf8().len() < 524288 {
		$payload = $payload.concat($payload)
	}
	var $dependencies = []
	var $index = 0.U64
	while $index < 63 {
		$dependencies = $dependencies.append({
			..TestData.library,
			name: "dep-${$index.to_str()}",
			run: ["x", $payload],
		})
		$index = $index + 1
	}
	project = TestData.project({
		..TestData.workflow_data,
		systems: NixBackend.supported_systems,
		builds: $dependencies.append({
			..TestData.library,
			name: "root",
			needs: $dependencies.map(|build| build.name),
		}),
		workflows: [{ name: "large", steps: [BuildArtifact("root")] }],
	})
	diagnostic = "workflow plan exceeds 16 MiB of distinct rendered requests"
	Project.validate(project).is_ok()
		and Project.build_closure(project, "root").map_ok(List.len) == Ok(64)
			and NixBackend.preflight(
				project,
				Request.Workflow("large"),
				"x86_64-linux",
				TestData.layout,
			) == Err(diagnostic)
				and NixBackend.plan(
					project,
					Request.Workflow("large"),
					"x86_64-linux",
					TestData.layout,
					plan_locks?,
				).map_ok(|plan| plan.steps) == Err(diagnostic)
}

# A closure exactly at the public cap succeeds (even repeated); adding one
# byte to its last definition fails before returning any executable prefix.
expect {
	var $payload = "x"
	while $payload.to_utf8().len() < 1048576 {
		$payload = $payload.concat($payload)
	}
	var $dependencies = []
	var $index = 0.U64
	while $index < 15 {
		$dependencies = $dependencies.append({
			..TestData.library,
			name: "dep-${$index.to_str()}",
			run: ["x", $payload.drop_prefix("x")],
		})
		$index = $index + 1
	}
	project = Project.validate(
		TestData.project({
			..TestData.workflow_data,
			builds: $dependencies.append({
				..TestData.library,
				name: "root",
				run: ["x", ""],
				needs: $dependencies.map(|build| build.name),
			}),
			workflows: [
				{
					name: "limit",
					steps: [BuildArtifact("root"), BuildArtifact("root")],
				},
			],
		}),
	)?
	baseline = NixBackend.prepare_atomic(
		project,
		Request.Build("root"),
		"x86_64-linux",
		TestData.layout,
		Unlimited,
	)?
	bytes = baseline.contents.to_utf8().len()
		+ baseline.argv.fold(0, |n, arg| n + arg.to_utf8().len())
	padding = Str.from_utf8($payload.to_utf8().take_first(16777216 - bytes)) ?? ""
	at_limit = {
		..project,
		builds: project.builds.map(
			|build| if build.name == "root" {
				{ ..build, run: ["x", padding] }
			} else build,
		),
	}
	over_limit = {
		..at_limit,
		builds: at_limit.builds.map(
			|build| if build.name == "root" {
				{ ..build, run: ["x", padding.concat("x")] }
			} else build,
		),
	}
	locks = plan_locks?
	plan = NixBackend.plan(
		at_limit,
		Request.Workflow("limit"),
		"x86_64-linux",
		TestData.layout,
		locks,
	)?
	diagnostic = "workflow plan exceeds 16 MiB of distinct rendered requests"
	plan.steps.len() == 2 and plan.steps.all(
		|step| match step.files.first() {
			Ok(flake) => flake.contents.to_utf8().len()
				+ step.argv.fold(0, |n, arg| n + arg.to_utf8().len()) == 16777216
			Err(_) => False
		},
	) and Project.validate(over_limit).is_ok() and NixBackend.preflight(
		at_limit,
		Request.Workflow("limit"),
		"x86_64-linux",
		TestData.layout,
	) == Ok({}) and NixBackend.preflight(
		over_limit,
		Request.Workflow("limit"),
		"x86_64-linux",
		TestData.layout,
	) == Err(diagnostic) and NixBackend.plan(
		over_limit,
		Request.Workflow("limit"),
		"x86_64-linux",
		TestData.layout,
		locks,
	).map_ok(|sequence| sequence.steps) == Err(diagnostic)
}

# The shared renderer charges every actual byte, including escaped Raw,
# environment/system scaffolding and command argv: exact fits, one less fails.
expect {
	project = Project.validate({
		..workflow_project,
		systems: NixBackend.supported_systems,
		requires_: workflow_project.requires_.append("raw"),
		raw: [
			{
				backend: "nix",
				target: "flake",
				value: Value.Attrs([{ name: "note", value: Value.Str("é\n\\\"") }]),
			},
		],
	})?
	request = Request.Run("check", ["", "é\n\\\"", "--"])
	unlimited = NixBackend.prepare_atomic(
		project,
		request,
		"x86_64-linux",
		TestData.layout,
		Unlimited,
	)?
	bytes = unlimited.contents.to_utf8().len()
		+ unlimited.argv.fold(0, |n, arg| n + arg.to_utf8().len())
	NixBackend.prepare_atomic(
		project,
		request,
		"x86_64-linux",
		TestData.layout,
		Limited(bytes),
	) == Ok(unlimited) and NixBackend.prepare_atomic(
		project,
		request,
		"x86_64-linux",
		TestData.layout,
		Limited(bytes - 1),
	) == Err("workflow plan exceeds 16 MiB of distinct rendered requests")
}

# Nested workflows preserve order, repetitions, argv, files and operations
# exactly: each returned step equals its independently requested atomic plan.
expect {
	sequence = workflow_plan(Request.Workflow("ci"))?
	library = workflow_plan(Request.Build("library"))?
	edit = workflow_plan(
		Request.Run("check", ["", "two words", "--literal", "a\nb", "$HOME"]),
	)?
	check = workflow_plan(Request.Run("check", []))?
	bundle = workflow_plan(Request.Build("bundle"))?
	sequence.steps == library.steps.concat(edit.steps).concat(check.steps)
		.concat(bundle.steps).concat(check.steps).concat(bundle.steps)
		.concat(bundle.steps)
		and sequence.steps.map(|step| step.action) == [
			Build("library"),
			Run("check"),
			Run("check"),
			Build("bundle"),
			Run("check"),
			Build("bundle"),
			Build("bundle"),
		]
}

# Diamond dependencies occur once per build operation, not once per workflow.
# Every explicit build snapshots again, even consecutive builds of one name.
expect {
	sequence = workflow_plan(Request.Workflow("ci"))?
	sequence.steps.map(|step| step.artifacts.map(|artifact| artifact.name)) == [
		["library"],
		[],
		[],
		["library", "app", "other", "bundle"],
		[],
		["library", "app", "other", "bundle"],
		["library", "app", "other", "bundle"],
	] and sequence.steps.map(
		|step| step.operations.keep_if(
			|operation| match operation {
				Snapshot(_) => True
				VerifyLocal(_) => False
			},
		).len(),
	) == [1, 0, 0, 1, 0, 1, 1]
}

# Each step reverifies local pins before staging; all derived locks are equal
# and none of the planned writes replaces the caller's authority.
expect {
	locks = plan_locks?
	before = Locks.encode(locks)
	sequence = workflow_plan(Request.Workflow("ci"))?
	atomic = workflow_plan(Request.Build("library"))?
	match atomic.steps {
		[library] => sequence.steps.all(
			|step| step.operations.first() == library.operations.first()
				and step.files.last() == library.files.last()
					and !step.files.any(
						|file| file.path == TestData.layout.lock_path,
					),
		) and Locks.encode(locks) == before
		_ => False
	}
}

# A selected task-only workflow ignores unrelated valid Guix environments.
# Selecting that environment later in a nested workflow rejects the whole plan.
expect {
	data = {
		..TestData.workflow_data,
		sources: [{ name: "guix", provider: GuixPackages("channels") }],
		environments: [TestData.builder, foreign],
		tasks: TestData.data.tasks.append(
			{ name: "foreign", environment: "foreign", run: ["python"] },
		),
		workflows: TestData.workflow_data.workflows.concat([
			{
				name: "later",
				steps: [RunWorkflow("one"), RunWorkflow("foreign")],
			},
			{ name: "foreign", steps: [RunTask("foreign", [])] },
		]),
	}
	project = TestData.project(data)
	locks = Locks.from_nix(project, TestData.layout, native_lock)?
	first = NixBackend.plan(
		project,
		Request.Workflow("one"),
		"x86_64-linux",
		TestData.layout,
		locks,
	)?
	later = NixBackend.plan(
		project,
		Request.Workflow("later"),
		"x86_64-linux",
		TestData.layout,
		locks,
	)
	first.steps.map(|step| step.action) == [Run("check")]
		and later.is_err() and later.map_ok(|plan| plan.steps) == NixBackend.plan(
			project,
			Request.Run("foreign", []),
			"x86_64-linux",
			TestData.layout,
			locks,
		).map_ok(|plan| plan.steps)
			and NixBackend.preflight(
				project,
				Request.Workflow("later"),
				"x86_64-linux",
				TestData.layout,
			).is_err()
}

# A later build's transitive dependency provider is checked before returning
# even the valid first task, not just the explicitly named build environment.
expect {
	project = TestData.project({
		..TestData.workflow_data,
		sources: [{ name: "guix", provider: GuixPackages("channels") }],
		environments: [TestData.builder, foreign],
		builds: [
			TestData.application,
			{ ..TestData.library, environment: "foreign" },
		],
		workflows: [
			{ name: "ci", steps: [RunTask("check", []), BuildArtifact("app")] },
		],
	})
	locks = Locks.from_nix(project, TestData.layout, native_lock)?
	first = NixBackend.plan(
		project,
		Request.Run("check", []),
		"x86_64-linux",
		TestData.layout,
		locks,
	)?
	later = NixBackend.plan(
		project,
		Request.Workflow("ci"),
		"x86_64-linux",
		TestData.layout,
		locks,
	)
	first.steps.map(|step| step.action) == [Run("check")]
		and later.is_err() and later.map_ok(|plan| plan.steps) == NixBackend.plan(
			project,
			Request.Build("app"),
			"x86_64-linux",
			TestData.layout,
			locks,
		).map_ok(|plan| plan.steps)
			and NixBackend.preflight(
				project,
				Request.Workflow("ci"),
				"x86_64-linux",
				TestData.layout,
			).is_err()
}

# A task-safe layout can collide only with a later build's generated runner.
# Full preflight and planning must catch that collision before the first task.
expect {
	project = TestData.project({
		..TestData.workflow_data,
		workflows: [
			{ name: "ci", steps: [RunTask("check", []), BuildArtifact("app")] },
		],
	})
	layout = { ..TestData.layout, workspace: "/generated/build-runner.py" }
	locks = plan_locks?
	NixBackend.preflight(
		project,
		Request.Run("check", []),
		"x86_64-linux",
		layout,
	) == Ok({}) and NixBackend.plan(
		project,
		Request.Run("check", []),
		"x86_64-linux",
		layout,
		locks,
	).is_ok() and NixBackend.preflight(
		project,
		Request.Workflow("ci"),
		"x86_64-linux",
		layout,
	) == Err("generated files, snapshot and authority must not overlap")
		and NixBackend.plan(
			project,
			Request.Workflow("ci"),
			"x86_64-linux",
			layout,
			locks,
		).map_ok(|plan| plan.steps) ==
			Err("generated files, snapshot and authority must not overlap")
}

# Task-compatible target selection cannot hide a later unsupported build.
expect {
	project = { ..workflow_project, systems: ["aarch64-darwin"] }
	locks = plan_locks?
	NixBackend.plan(
		project,
		Request.Run("check", []),
		"aarch64-darwin",
		TestData.layout,
		locks,
	).is_ok() and NixBackend.plan(
		project,
		Request.Workflow("verify"),
		"aarch64-darwin",
		TestData.layout,
		locks,
	).map_ok(|plan| plan.steps) ==
		Err("sandboxed builds currently require target x86_64-linux")
		and NixBackend.preflight(
			project,
			Request.Workflow("verify"),
			"aarch64-darwin",
			TestData.layout,
		) == Err("sandboxed builds currently require target x86_64-linux")
}

# Missing or cyclic later build dependencies are whole-project failures,
# never partial plans that leave a valid first task available to execute.
expect {
	locks = plan_locks?
	[
		{ ..TestData.library, needs: ["missing"] },
		{ ..TestData.library, needs: ["app"] },
	].all(
		|library| {
			project = TestData.project({
				..TestData.workflow_data,
				builds: [TestData.application, library],
				workflows: [
					{
						name: "ci",
						steps: [RunTask("check", []), BuildArtifact("app")],
					},
				],
			})
			NixBackend.preflight(
				project,
				Request.Workflow("ci"),
				"x86_64-linux",
				TestData.layout,
			).is_err() and NixBackend.plan(
				project,
				Request.Workflow("ci"),
				"x86_64-linux",
				TestData.layout,
				locks,
			).is_err()
		},
	)
}

# A changed source needed by a later build rejects the supplied authority
# after successful pure preflight; planning cannot return a runnable prefix.
expect {
	project = {
		..workflow_project,
		build_sources: [{ name: "assets", ref: "path:./changed-assets" }],
	}
	NixBackend.preflight(
		project,
		Request.Workflow("verify"),
		"x86_64-linux",
		TestData.layout,
	) == Ok({}) and match NixBackend.plan(
		project,
		Request.Workflow("verify"),
		"x86_64-linux",
		TestData.layout,
		plan_locks?,
	) {
		Err(message) => message.contains("update")
		Ok(_) => False
	}
}

# Empty workflows, including nested empty expansion, return zero steps rather
# than an invented Generate request or a requirement to select an environment.
expect ["empty", "nothing"].all(
	|name| workflow_plan(Request.Workflow(name))
		.map_ok(|plan| plan.steps) == Ok([])
		and NixBackend.preflight(
			workflow_project,
			Request.Workflow(name),
			"x86_64-linux",
			TestData.layout,
		) == Ok({}),
)

# Empty expansion skips unrelated provider capability checks, not global
# required features, Raw, extensions, target declarations or semantic validity.
expect {
	project = TestData.project({
		..TestData.workflow_data,
		sources: [{ name: "guix", provider: GuixPackages("channels") }],
		environments: [TestData.builder, foreign],
	})
	locks = Locks.from_nix(project, TestData.layout, native_lock)?
	NixBackend.plan(
		project,
		Request.Workflow("empty"),
		"x86_64-linux",
		TestData.layout,
		locks,
	).map_ok(|plan| plan.steps) == Ok([]) and [
		{
			..project,
			raw: [{ backend: "nix", target: "missing", value: Value.Attrs([]) }],
		},
		{
			..project,
			extensions: [{ kind: "service", name: "db", value: Value.Attrs([]) }],
		},
		{ ..project, systems: ["x86_64-linux", "riscv64-linux"] },
		{ ..project, tasks: [{ name: "bad", environment: "missing", run: ["x"] }] },
	].all(
		|invalid| NixBackend.preflight(
			invalid,
			Request.Workflow("empty"),
			"x86_64-linux",
			TestData.layout,
		).is_err() and NixBackend.plan(
			invalid,
			Request.Workflow("empty"),
			"x86_64-linux",
			TestData.layout,
			locks,
		).is_err(),
	)
}

# Keep all known markers so this no-op reaches backend feature preflight,
# rather than failing structural validation for missing build/workflow markers.
expect {
	project = {
		..workflow_project,
		requires_: workflow_project.requires_.append("future"),
	}
	Project.validate(project).is_ok() and NixBackend.preflight(
		project,
		Request.Workflow("empty"),
		"x86_64-linux",
		TestData.layout,
	) == Err("unsupported features: future") and NixBackend.plan(
		project,
		Request.Workflow("empty"),
		"x86_64-linux",
		TestData.layout,
		plan_locks?,
	).map_ok(|plan| plan.steps) == Err("unsupported features: future")
}

# No-op workflows still require a declared target, a safe caller layout and
# matching authority; absence of runnable steps never bypasses global checks.
expect {
	locks = plan_locks?
	unsafe = { ..TestData.layout, generated_root: "/work/snapshot/nix" }
	changed = {
		..workflow_project,
		build_sources: [{ name: "assets", ref: "path:./changed-assets" }],
	}
	NixBackend.preflight(
		workflow_project,
		Request.Workflow("empty"),
		"aarch64-linux",
		TestData.layout,
	).is_err() and NixBackend.plan(
		workflow_project,
		Request.Workflow("empty"),
		"aarch64-linux",
		TestData.layout,
		locks,
	).is_err() and NixBackend.preflight(
		workflow_project,
		Request.Workflow("empty"),
		"x86_64-linux",
		unsafe,
	).is_err() and NixBackend.plan(
		workflow_project,
		Request.Workflow("empty"),
		"x86_64-linux",
		unsafe,
		locks,
	).is_err() and NixBackend.plan(
		changed,
		Request.Workflow("empty"),
		"x86_64-linux",
		TestData.layout,
		locks,
	).is_err()
}

# Unknown workflows, bad nested references, cycles and NUL extras are rejected
# through the backend boundary even when callers did not validate the IR first.
expect {
	locks = plan_locks?
	workflow_plan(Request.Workflow("missing")).is_err() and [
		[RunWorkflow("missing")],
		[RunWorkflow("ci")],
		[RunTask("missing", [])],
		[BuildArtifact("missing")],
		[RunTask("check", [Str.from_utf8([0]) ?? ""])],
	].all(
		|steps| {
			project = { ..workflow_project, workflows: [{ name: "ci", steps }] }
			NixBackend.preflight(
				project,
				Request.Workflow("ci"),
				"x86_64-linux",
				TestData.layout,
			).is_err() and NixBackend.plan(
				project,
				Request.Workflow("ci"),
				"x86_64-linux",
				TestData.layout,
				locks,
			).is_err()
		},
	)
}
