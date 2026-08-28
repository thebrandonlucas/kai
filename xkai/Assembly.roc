# TODO: comment
Assembly := [].{
	SourceFile := { contents : Str, destination : Str }

	Dependency := { name : Str, path : Str }

	SourceBundle := {
		app_dependencies : List(Assembly.Dependency),
		app_imports : List(Str),
		files : List(Assembly.SourceFile),
	}

	RegistryEntry := {
		app_dependency : Assembly.Dependency,
		expression : Str,
		import_line : Str,
	}

	PluginSource := { contents : Str, filename : Str }

	PluginInput := {
		backends : List(Assembly.PluginSource),
		commands : List(Assembly.PluginSource),
		contents : Str,
		filename : Str,
		implementations : List(Assembly.PluginSource),
		module_name : Str,
	}

	CustomDependencies := {
		backends : List(Assembly.Dependency),
		commands : List(Assembly.Dependency),
		implementations : List(Assembly.Dependency),
		plugin : List(Assembly.Dependency),
	}

	BuildProfile := {
		bundles : List(Assembly.SourceBundle),
		custom_dependencies : Assembly.CustomDependencies,
		fallback_entries : List(Assembly.RegistryEntry),
		platform_url : Str,
	}

	BuildPlan := { app_source : Str, files : List(Assembly.SourceFile) }

	AssemblyProblem := [
		DuplicateDestination(Str),
		InvalidModuleFilename(Str),
		StageEscapingDestination(Str),
	]

	package_source : List(Str), List(Assembly.Dependency) -> Str
	package_source = |modules, dependencies| {
		dependency_source = dependencies.map(
			|dependency| "${dependency.name}: \"${dependency.path}\"",
		)
		Str.join_with(
			[
				"package [",
				Str.join_with(modules, ", "),
				"] { ",
				Str.join_with(dependency_source, ", "),
				" }\n",
			],
			"",
		)
	}

	bundle_files : List(Assembly.SourceBundle) -> List(Assembly.SourceFile)
	bundle_files = |bundles|
		match bundles {
			[] => []
			[first, .. as rest] => first.files.concat(Assembly.bundle_files(rest))
		}

	bundle_dependencies : List(Assembly.SourceBundle) -> List(Assembly.Dependency)
	bundle_dependencies = |bundles|
		match bundles {
			[] => []
			[first, .. as rest] => first.app_dependencies.concat(
				Assembly.bundle_dependencies(rest),
			)
		}

	bundle_imports : List(Assembly.SourceBundle) -> List(Str)
	bundle_imports = |bundles|
		match bundles {
			[] => []
			[first, .. as rest] => first.app_imports.concat(
				Assembly.bundle_imports(rest),
			)
		}

	component_files :
		Str,
		Str,
		List(Assembly.PluginSource),
		List(Assembly.Dependency) -> List(
			Assembly.SourceFile,
		)
	component_files = |package_name, component_name, files, dependencies| {
		root = "${package_name}/${component_name}"
		modules = files.map(|file| file.filename.drop_suffix(".roc"))
		files.map(
			|file| {
				destination: "${root}/${file.filename}",
				contents: file.contents,
			},
		).concat([
			{
				destination: "${root}/main.roc",
				contents: Assembly.package_source(modules, dependencies),
			},
		])
	}

	plugin_files :
		Assembly.PluginInput,
		U64,
		Assembly.CustomDependencies -> List(
			Assembly.SourceFile,
		)
	plugin_files = |plugin, index, dependencies| {
		package_name = "custom${U64.to_str(index)}"
		package_dependencies = [
			{ name: "backends", path: "./backends/main.roc" },
			{ name: "commands", path: "./commands/main.roc" },
			{ name: "implementations", path: "./implementations/main.roc" },
		].concat(dependencies.plugin)
		implementation_dependencies = [
			{ name: "backends", path: "../backends/main.roc" },
			{ name: "commands", path: "../commands/main.roc" },
		].concat(dependencies.implementations)

		[
			{
				destination: "${package_name}/main.roc",
				contents: Assembly.package_source(
					[plugin.module_name],
					package_dependencies,
				),
			},
			{
				destination: "${package_name}/${plugin.filename}",
				contents: plugin.contents,
			},
		]
			.concat(
				Assembly.component_files(
					package_name,
					"commands",
					plugin.commands,
					dependencies.commands,
				),
			)
			.concat(
				Assembly.component_files(
					package_name,
					"backends",
					plugin.backends,
					dependencies.backends,
				),
			)
			.concat(
				Assembly.component_files(
					package_name,
					"implementations",
					plugin.implementations,
					implementation_dependencies,
				),
			)
	}

	custom_files_from :
		List(Assembly.PluginInput),
		Assembly.CustomDependencies,
		U64 -> List(
			Assembly.SourceFile,
		)
	custom_files_from = |plugins, dependencies, index|
		match plugins {
			[] => []
			[first, .. as rest] => Assembly.plugin_files(
				first,
				index,
				dependencies,
			).concat(
				Assembly.custom_files_from(rest, dependencies, index + 1),
			)
		}

	make_custom_files :
		List(Assembly.PluginInput),
		Assembly.CustomDependencies -> List(
			Assembly.SourceFile,
		)
	make_custom_files = |plugins, dependencies|
		Assembly.custom_files_from(plugins, dependencies, 0)

	make_custom_entries : List(Assembly.PluginInput) -> List(
		Assembly.RegistryEntry,
	)
	make_custom_entries = |plugins|
		plugins.map_with_index(
			|plugin, index| {
				name = "Custom${U64.to_str(index)}"
				package_name = "custom${U64.to_str(index)}"
				{
					app_dependency: { name: package_name, path: "./${package_name}/main.roc" },
					import_line: "import ${package_name}.${plugin.module_name} as ${name}",
					expression: Str.join_with(
						[
							"{ backends: ${name}.backends,",
							"commands: ${name}.commands,",
							"implementations: ${name}.implementations,",
							"name: ${name}.name,",
							"project_configs: [] }",
						],
						" ",
					),
				}
			},
		)

	render_app :
		Str,
		List(Assembly.SourceBundle),
		List(Assembly.RegistryEntry),
		List(
			Assembly.RegistryEntry,
		) -> Str
	render_app = |platform_url, bundles, custom_entries, fallback_entries| {
		dependencies = Assembly.bundle_dependencies(bundles)
			.concat(fallback_entries.map(|entry| entry.app_dependency))
			.concat(custom_entries.map(|entry| entry.app_dependency))
		dependency_lines = dependencies.map(
			|dependency| "\t${dependency.name}: \"${dependency.path}\",",
		)
		import_lines = Assembly.bundle_imports(bundles)
			.concat(fallback_entries.map(|entry| entry.import_line))
			.concat(custom_entries.map(|entry| entry.import_line))
		registry_lines = custom_entries.concat(fallback_entries).map(
			|entry| "\t${entry.expression},",
		)

		Str.join_with(
			[
				"app [main!] {",
				"\tpf: platform \"${platform_url}\",",
			].concat(dependency_lines).concat([
				"}",
				"",
			]).concat(import_lines).concat([
				"",
				"registry = [",
			]).concat(registry_lines).concat([
				"]",
				"",
				"main! = |args| Executor.run!(args, registry)",
			]),
			"\n",
		)
	}

	valid_module_name : Str -> Bool
	valid_module_name = |name| {
		match name.to_utf8() {
			[] => Bool.False
			[first, .. as rest] =>
				first >= 65 and first <= 90 and List.all(
					rest,
					|byte|
						(byte >= 65 and byte <= 90) or
							(byte >= 97 and byte <= 122) or
								(byte >= 48 and byte <= 57) or byte == 95,
				)
			}
	}

	validate_module_filename : Str -> Try({}, Assembly.AssemblyProblem)
	validate_module_filename = |filename| {
		module_name = filename.drop_suffix(".roc")
		if filename.ends_with(".roc") and Assembly.valid_module_name(module_name) {
			Ok({})
		} else {
			Err(InvalidModuleFilename(filename))
		}
	}

	validate_plugin_sources : List(Assembly.PluginSource) -> Try(
		{},
		Assembly.AssemblyProblem,
	)
	validate_plugin_sources = |sources|
		match sources {
			[] => Ok({})
			[first, .. as rest] => {
				Assembly.validate_module_filename(first.filename)?
				Assembly.validate_plugin_sources(rest)
			}
		}

	validate_plugins : List(Assembly.PluginInput) -> Try(
		{},
		Assembly.AssemblyProblem,
	)
	validate_plugins = |plugins|
		match plugins {
			[] => Ok({})
			[first, .. as rest] => {
				Assembly.validate_module_filename(first.filename)?
				Assembly.validate_plugin_sources(first.commands)?
				Assembly.validate_plugin_sources(first.backends)?
				Assembly.validate_plugin_sources(first.implementations)?
				Assembly.validate_plugins(rest)
			}
		}

	validate_destinations :
		List(Assembly.SourceFile),
		List(Str) -> Try(
			{},
			Assembly.AssemblyProblem,
		)
	validate_destinations = |files, seen|
		match files {
			[] => Ok({})
			[first, .. as rest] => {
				parts = first.destination.split_on("/")
				if first.destination.is_empty() or
					first.destination.starts_with("/") or
						List.any(parts, |part| part == "..") {
					Err(StageEscapingDestination(first.destination))
				} else if seen.contains(first.destination) {
					Err(DuplicateDestination(first.destination))
				} else {
					Assembly.validate_destinations(rest, [first.destination].concat(seen))
				}
			}
		}

	assemble :
		Assembly.BuildProfile,
		List(Assembly.PluginInput) -> Try(
			Assembly.BuildPlan,
			Assembly.AssemblyProblem,
		)
	assemble = |profile, plugins| {
		Assembly.validate_plugins(plugins)?
		assembled_custom_files = Assembly.make_custom_files(
			plugins,
			profile.custom_dependencies,
		)
		assembled_custom_entries = Assembly.make_custom_entries(plugins)
		assembled_app_source = Assembly.render_app(
			profile.platform_url,
			profile.bundles,
			assembled_custom_entries,
			profile.fallback_entries,
		)
		assembled_files = Assembly.bundle_files(profile.bundles).concat(
			assembled_custom_files,
		)
		Assembly.validate_destinations(
			assembled_files.concat([
				{ destination: "main.roc", contents: assembled_app_source },
			]),
			[],
		)?
		Ok({ app_source: assembled_app_source, files: assembled_files })
	}
}
