# Authoring cardinality checks feed the shared whole-project validator.
import Config
import Val
import model.Value
import model.Model
import model.Project

## Convert the Kaifile settings to std's model, then share semantic
## validation with the backends.
## Setting cardinality belongs here because the model stores only one value.
ConfigToModel :: [].{
	Acc : {
		names : List(Str),
		systems : List(List(Str)),
		sources : List(Model.Source),
		guix_channels : List(Model.GuixChannel),
		inputs : List(Model.Input),
		follows : List(Model.Follows),
		environments : List(Model.Environment),
		shells : List(Model.Shell),
		tasks : List(Model.Task),
		build_sources : List(Model.BuildSource),
		fetches : List(Model.Fetch),
		cargo_vendors : List(Model.CargoVendor),
		builds : List(Model.Build),
		workflows : List(Model.Workflow),
		extensions : List(Model.Extension),
		raw : List(Model.Raw),
	}

	## Explicit target defaults; never inferred from the compiling host.
	default_systems : List(Str)
	default_systems = [
		"x86_64-linux",
		"aarch64-linux",
	]

	## The settings as Kaifile model text, or why they are invalid.
	render : List(Config.Setting) -> Try(Str, Str)
	render = |settings|
		ConfigToModel.convert(settings).map_ok(|model| model.to_str())

	convert : List(Config.Setting) -> Try(Model, Str)
	convert = |settings| {
		initial : Acc
		initial = {
			names: [],
			systems: [],
			sources: [],
			guix_channels: [],
			inputs: [],
			follows: [],
			environments: [],
			shells: [],
			tasks: [],
			build_sources: [],
			fetches: [],
			cargo_vendors: [],
			builds: [],
			workflows: [],
			extensions: [],
			raw: [],
		}
		acc = settings.fold(Ok(initial), |result, setting| add(result?, setting))?
		name = match acc.names {
			[] => return Err("MissingName: declare Name once")
			[one] => one
			_ => return Err("DuplicateName: declare Name once")
		}
		systems = match acc.systems {
			[] => default_systems
			[one] => one
			_ => return Err("DuplicateSystems: declare Systems at most once")
		}
		requires_ =
			(if (acc.extensions.is_empty()) [] else ["extensions"])
				.concat(if (acc.raw.is_empty()) [] else ["raw"])
				.concat(if (acc.build_sources.is_empty()) [] else ["sources"])
				.concat(if (acc.fetches.is_empty()) [] else ["fetches"])
				.concat(if (acc.cargo_vendors.is_empty()) [] else ["cargo"])
				.concat(if (acc.builds.is_empty()) [] else ["builds"])
				.concat(if (acc.workflows.is_empty()) [] else ["workflows"])
				.concat(if (acc.builds.all(|b| b.files == All)) [] else ["files"])
				.concat(if (uses_env(acc)) ["env"] else [])
				.concat(if (acc.tasks.all(|t| t.secrets.is_empty())) [] else ["secrets"])
				.concat(
					if (acc.tasks.all(|t| t.optional_environment_variables.is_empty()))
						[]
					else
						["optional_environment_variables"],
				)
				.concat(if (acc.tasks.all(|t| t.needs.is_empty())) [] else ["task_needs"])
				.concat(if (acc.builds.any(|b| b.revision)) ["revision"] else [])
				.concat(if (uses_may_fail(acc)) ["may_fail"] else [])
				.concat(if (acc.environments.any(|e| e.pure)) ["pure"] else [])
				.concat(if (uses_aliases(acc)) ["aliases"] else [])
				.concat(if (uses_rust_toolchain(acc)) ["rust-toolchain"] else [])
				.concat(if (acc.follows.is_empty()) [] else ["follows"])
		Project.validate(
			Model.{
				format: Model.current_format,
				name,
				requires_,
				systems,
				sources: acc.sources,
				guix_channels: acc.guix_channels,
				inputs: acc.inputs,
				follows: acc.follows,
				environments: acc.environments,
				shells: acc.shells,
				tasks: acc.tasks,
				build_sources: acc.build_sources,
				fetches: acc.fetches,
				cargo_vendors: acc.cargo_vendors,
				builds: acc.builds,
				workflows: acc.workflows,
				extensions: acc.extensions,
				raw: acc.raw,
			},
		)
	}

	add : Acc, Config.Setting -> Try(Acc, Str)
	add = |acc, setting| {
		next = match setting {
			Name(name) => { ..acc, names: acc.names.append(name) }
			Systems(systems) => {
				..acc,
				systems: acc.systems.append(systems.map(|s| s.to_str())),
			}
			Packages(name, source) => {
				..acc,
				sources: acc.sources.append({
					name: name.to_str(),
					provider: provider(source),
				}),
			}
			Input(name, ref) => {
				..acc,
				inputs: acc.inputs.append({
					name: name.to_str(),
					url: ref.to_str(),
					kind: Flake,
				}),
			}
			Overlay(name, ref) => {
				..acc,
				inputs: acc.inputs.append({
					name: name.to_str(),
					url: ref.to_str(),
					kind: Overlay,
				}),
			}
			Follows(overlay, input, source) => {
				..acc,
				follows: acc.follows.append({
					overlay: overlay.to_str(),
					input,
					source: source.to_str(),
				}),
			}
			GuixChannel(name, url, branch, Introduction(commit, signer)) => {
				..acc,
				guix_channels: acc.guix_channels.append({
					name: name.to_str(),
					url,
					branch,
					introduction: { commit, signer },
				}),
			}
			Environment(name, inner) => {
				..acc,
				environments: acc.environments.append(
					environment(name.to_str(), inner)?,
				),
			}
			Shell(name, inner) => {
				..acc,
				shells: acc.shells.append(shell(name.to_str(), inner)?),
			}
			Task(name, inner) => {
				..acc,
				tasks: acc.tasks.append(task(name.to_str(), inner)?),
			}
			Source(name, ref) => {
				..acc,
				build_sources: acc.build_sources.append({
					name: name.to_str(),
					ref: ref.to_str(),
				}),
			}
			Fetch(name, files) => {
				..acc,
				fetches: acc.fetches.append({
					name: name.to_str(),
					files: files.map_try(
						|f|
							Ok({
								system: f.system.to_str(),
								url: f.url,
								hash: Project.sri_sha256(f.sha256)
									.map_err(|_| "invalid sha256 in Fetch ${name.to_str()}")?,
							}),
					)?,
				}),
			}
			CargoVendor(name, lock) => {
				..acc,
				cargo_vendors: acc.cargo_vendors.append({ name: name.to_str(), lock }),
			}
			Build(name, inner) => {
				..acc,
				builds: acc.builds.append(build(name.to_str(), inner)?),
			}
			Workflow(name, steps) => {
				..acc,
				workflows: acc.workflows.append(workflow(name.to_str(), steps)?),
			}
			Custom(kind, name, value) => {
				..acc,
				extensions: acc.extensions.append({
					kind,
					name,
					value: to_value(value),
				}),
			}
			Raw(backend, target, value) => {
				..acc,
				raw: acc.raw.append({ backend, target, value: to_value(value) }),
			}
		}
		Ok(next)
	}

	workflow : Str, List(Config.WorkflowStep) -> Try(Model.Workflow, Str)
	workflow = |name, steps| {
		draft = steps.fold(
			{ steps: [], descriptions: [] },
			|acc, step|
				match step {
					RunTask(task, argv) => {
						..acc,
						steps: acc.steps.append(RunTask(task.to_str(), argv)),
					}
					BuildArtifact(build) => {
						..acc,
						steps: acc.steps.append(BuildArtifact(build.to_str())),
					}
					RunWorkflow(child) => {
						..acc,
						steps: acc.steps.append(RunWorkflow(child.to_str())),
					}
					MayFail(inner) => {
						..acc,
						steps: acc.steps.append(MayFail(may_fail_step(inner))),
					}
					Description(text) => { ..acc, descriptions: acc.descriptions.append(text) }
				},
		)
		Ok({
			name,
			description: single_description(draft.descriptions, "workflow ${name}")?,
			steps: draft.steps,
		})
	}

	may_fail_step : Config.Step -> Model.Step
	may_fail_step = |step|
		match step {
			RunTask(name, argv) => RunTask(name.to_str(), argv)
			BuildArtifact(name) => BuildArtifact(name.to_str())
			RunWorkflow(name) => RunWorkflow(name.to_str())
		}

	provider : Config.PackageSource -> Model.Provider
	provider = |source|
		match source {
			Auto => Auto
			From(NixPackages(ref)) => NixPackages(ref.to_str())
			From(GuixPackages(channel)) => GuixPackages(channel)
		}

	environment :
		Str, List(Config.EnvironmentSetting) -> Try(Model.Environment, Str)
	environment = |name, inner| {
		draft = inner.fold(
			{
				tools: [],
				overlays: [],
				parents: [],
				envs: [],
				pures: 0.U64,
				aliases: [],
				toolchains: [],
			},
			|acc, setting|
				match setting {
					Tools(tools) => {
						..acc,
						tools: acc.tools.append(tools.map(|tool| tool.to_ir())),
					}
					Overlays(overlays) => {
						..acc,
						overlays: acc.overlays.append(
							overlays.map(|overlay| overlay.to_str()),
						),
					}
					Extend(parent) => { ..acc, parents: acc.parents.append(parent.to_str()) }
					Env(pairs) => { ..acc, envs: acc.envs.append(variables(pairs)) }
					Pure => { ..acc, pures: acc.pures + 1 }
					Alias(alias, tool, binary) => {
						..acc,
						aliases: acc.aliases.append({ name: alias, tool: tool.to_ir(), binary }),
					}
					RustToolchain(text) => {
						..acc,
						toolchains: acc.toolchains.append(Toml(text)),
					}
				},
		)
		if draft.tools.len() > 1 {
			return Err("DuplicateTools: environment ${name}")
		}
		if draft.toolchains.len() > 1 {
			return Err("DuplicateRustToolchain: environment ${name}")
		}
		if draft.overlays.len() > 1 {
			return Err("DuplicateOverlays: environment ${name}")
		}
		if draft.parents.len() > 1 {
			return Err("DuplicateExtend: environment ${name}")
		}
		if draft.pures > 1 {
			return Err("DuplicatePure: environment ${name}")
		}
		Ok({
			name,
			parents: draft.parents,
			tools: draft.tools.first() ?? [],
			overlays: draft.overlays.first() ?? [],
			env: single_env(draft.envs, "environment ${name}")?,
			pure: draft.pures == 1,
			aliases: draft.aliases,
			rust_toolchain: draft.toolchains.first() ?? None,
		})
	}

	shell : Str, List(Config.ShellSetting) -> Try(Model.Shell, Str)
	shell = |name, inner| {
		draft = inner.fold(
			{ environments: [], descriptions: [] },
			|acc, setting|
				match setting {
					Use(env) => { ..acc, environments: acc.environments.append(env.to_str()) }
					Description(text) => { ..acc, descriptions: acc.descriptions.append(text) }
				},
		)
		environment_name = match draft.environments {
			[one] => one
			[] => return Err("MissingUse: shell ${name}")
			_ => return Err("DuplicateUse: shell ${name}")
		}
		Ok({
			name,
			environment: environment_name,
			description: single_description(draft.descriptions, "shell ${name}")?,
		})
	}

	task : Str, List(Config.TaskSetting) -> Try(Model.Task, Str)
	task = |name, inner| {
		draft = inner.fold(
			{
				environments: [],
				runs: [],
				envs: [],
				secrets: [],
				optional_environment_variables: [],
				needs: [],
				descriptions: [],
			},
			|acc, setting|
				match setting {
					Use(env) => { ..acc, environments: acc.environments.append(env.to_str()) }
					Run(argv) => { ..acc, runs: acc.runs.append(argv) }
					Env(pairs) => { ..acc, envs: acc.envs.append(variables(pairs)) }
					Secrets(names) => { ..acc, secrets: acc.secrets.append(names) }
					OptionalEnvironmentVariables(names) => {
						..acc,
						optional_environment_variables: acc.optional_environment_variables
							.append(names),
					}
					Needs(needs) => {
						..acc,
						needs: acc.needs.append(needs.map(|need| need.to_str())),
					}
					Description(text) => { ..acc, descriptions: acc.descriptions.append(text) }
				},
		)
		environment_name = match draft.environments {
			[one] => one
			[] => return Err("MissingUse: task ${name}")
			_ => return Err("DuplicateUse: task ${name}")
		}
		run = match draft.runs {
			[one] => one
			[] => return Err("MissingRun: task ${name}")
			_ => return Err("DuplicateRun: task ${name}")
		}
		secrets = match draft.secrets {
			[] => []
			[one] => one
			_ => return Err("DuplicateSecrets: task ${name}")
		}
		optional_environment_variables = match draft.optional_environment_variables {
			[] => []
			[one] => one
			_ => return Err("DuplicateOptionalEnvironmentVariables: task ${name}")
		}
		if draft.needs.len() > 1 {
			return Err("DuplicateNeeds: task ${name}")
		}
		Ok({
			name,
			environment: environment_name,
			run,
			env: single_env(draft.envs, "task ${name}")?,
			secrets,
			optional_environment_variables,
			needs: draft.needs.first() ?? [],
			description: single_description(draft.descriptions, "task ${name}")?,
		})
	}

	build : Str, List(Config.BuildSetting) -> Try(Model.Build, Str)
	build = |name, inner| {
		draft = inner.fold(
			{
				environments: [],
				inputs: [],
				needs: [],
				runs: [],
				outputs: [],
				files: [],
				envs: [],
				revisions: 0.U64,
				descriptions: [],
			},
			|acc, setting|
				match setting {
					Use(env) => { ..acc, environments: acc.environments.append(env.to_str()) }
					Inputs(inputs) => {
						..acc,
						inputs: acc.inputs.append(inputs.map(|input| input.to_str())),
					}
					Needs(needs) => {
						..acc,
						needs: acc.needs.append(needs.map(|need| need.to_str())),
					}
					Run(argv) => { ..acc, runs: acc.runs.append(argv) }
					Output(path) => { ..acc, outputs: acc.outputs.append(path) }
					Files(paths) => { ..acc, files: acc.files.append(paths) }
					Env(pairs) => { ..acc, envs: acc.envs.append(variables(pairs)) }
					Revision => { ..acc, revisions: acc.revisions + 1 }
					Description(text) => { ..acc, descriptions: acc.descriptions.append(text) }
				},
		)
		environment_name = match draft.environments {
			[one] => one
			[] => return Err("MissingUse: build ${name}")
			_ => return Err("DuplicateUse: build ${name}")
		}
		run = match draft.runs {
			[one] => one
			[] => return Err("MissingRun: build ${name}")
			_ => return Err("DuplicateRun: build ${name}")
		}
		output = match draft.outputs {
			[one] => one
			[] => return Err("MissingOutput: build ${name}")
			_ => return Err("DuplicateOutput: build ${name}")
		}
		if draft.inputs.len() > 1 {
			return Err("DuplicateInputs: build ${name}")
		}
		if draft.needs.len() > 1 {
			return Err("DuplicateNeeds: build ${name}")
		}
		if draft.revisions > 1 {
			return Err("DuplicateRevision: build ${name}")
		}
		files = match draft.files {
			[] => All
			[one] => Only(one)
			_ => return Err("DuplicateFiles: build ${name}")
		}
		Ok({
			name,
			environment: environment_name,
			inputs: draft.inputs.first() ?? [],
			needs: draft.needs.first() ?? [],
			run,
			output,
			files,
			env: single_env(draft.envs, "build ${name}")?,
			revision: draft.revisions == 1,
			description: single_description(draft.descriptions, "build ${name}")?,
		})
	}

	variables : List((Str, Str)) -> List(Model.Variable)
	variables = |pairs| pairs.map(|(name, value)| { name, value })

	single_env : List(List(Model.Variable)), Str -> Try(List(Model.Variable), Str)
	single_env = |envs, declaration|
		match envs {
			[] => Ok([])
			[one] => Ok(one)
			_ => Err("DuplicateEnv: ${declaration}")
		}

	uses_may_fail : Acc -> Bool
	uses_may_fail = |acc|
		acc.workflows.any(
			|w| w.steps.any(
				|step| match step {
					MayFail(_) => Bool.True
					_ => Bool.False
				},
			),
		)

	single_description : List(Str), Str -> Try(Str, Str)
	single_description = |descriptions, declaration|
		match descriptions {
			[] => Ok("")
			[one] => Ok(one)
			_ => Err("DuplicateDescription: ${declaration}")
		}

	uses_env : Acc -> Bool
	uses_env = |acc|
		acc.environments.any(|e| !e.env.is_empty())
			or acc.tasks.any(|t| !t.env.is_empty())
			or acc.builds.any(|b| !b.env.is_empty())

	uses_aliases : Acc -> Bool
	uses_aliases = |acc| acc.environments.any(|e| !e.aliases.is_empty())

	uses_rust_toolchain : Acc -> Bool
	uses_rust_toolchain = |acc|
		acc.environments.any(|e| e.rust_toolchain != None)

	to_value : Val -> Value
	to_value = |val|
		match val {
			Str(s) => Value.Str(s)
			Int(n) => Value.Int(n)
			Bool(b) => Value.Bool(b)
			List(items) => Value.List(items.map(to_value))
			Attrs(pairs) => Value.Attrs(
				pairs.map(|(name, v)| { name, value: to_value(v) }),
			)
		}
}
