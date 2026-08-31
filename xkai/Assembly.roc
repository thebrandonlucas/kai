# TODO: comment
Assembly := [].{
	SourceFile := { contents : Str, destination : Str }

	PluginFile := { contents : Str, filename : Str }

	PluginSource := {
		backends : List(Assembly.PluginFile),
		implementations : List(Assembly.PluginFile),
		module_name : Str,
		module_source : Assembly.PluginFile,
		package_name : Str,
		schemas : List(Assembly.PluginFile),
	}

	Dependency := { name : Str, path : Str }

	SourceBundle := {
		app_dependencies : List(Assembly.Dependency),
		app_imports : List(Str),
		files : List(Assembly.SourceFile),
	}

	BuildProfile := {
		bundles : List(Assembly.SourceBundle),
		embedded_plugins : List(Assembly.PluginSource),
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
		List(Assembly.PluginFile),
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

	nested_dependencies :
		List(Assembly.Dependency) -> List(Assembly.Dependency)
	nested_dependencies = |dependencies|
		dependencies.map(
			|dependency| {
				name: dependency.name,
				path: "../${dependency.path}",
			},
		)

	stage_plugin :
		Assembly.PluginSource,
		List(Assembly.Dependency) -> List(
			Assembly.SourceFile,
		)
	stage_plugin = |declared_plugin, external_dependencies| {
		package_name = declared_plugin.package_name
		nested_external_dependencies = Assembly.nested_dependencies(
			external_dependencies,
		)
		package_dependencies = [
			{ name: "backends", path: "./backends/main.roc" },
			{ name: "implementations", path: "./implementations/main.roc" },
			{ name: "kai", path: "../package.roc" },
			{ name: "parser", path: "../parser/main.roc" },
			{ name: "schemas", path: "./schemas/main.roc" },
		].concat(external_dependencies)
		component_dependencies = [
			{ name: "kai", path: "../../package.roc" },
			{ name: "parser", path: "../../parser/main.roc" },
		].concat(nested_external_dependencies)
		implementation_dependencies = [
			{ name: "backends", path: "../backends/main.roc" },
			{ name: "kai", path: "../../package.roc" },
			{ name: "parser", path: "../../parser/main.roc" },
			{ name: "schemas", path: "../schemas/main.roc" },
		].concat(nested_external_dependencies)

		[
			{
				destination: "${package_name}/main.roc",
				contents: Assembly.package_source(
					[declared_plugin.module_name],
					package_dependencies,
				),
			},
			{
				destination: "${package_name}/${declared_plugin.module_source.filename}",
				contents: declared_plugin.module_source.contents,
			},
		]
			.concat(
				Assembly.component_files(
					package_name,
					"schemas",
					declared_plugin.schemas,
					component_dependencies,
				),
			)
			.concat(
				Assembly.component_files(
					package_name,
					"backends",
					declared_plugin.backends,
					component_dependencies,
				),
			)
			.concat(
				Assembly.component_files(
					package_name,
					"implementations",
					declared_plugin.implementations,
					implementation_dependencies,
				),
			)
	}

	stage_plugins :
		List(Assembly.PluginSource),
		List(Assembly.Dependency) -> List(
			Assembly.SourceFile,
		)
	stage_plugins = |plugins, external_dependencies|
		match plugins {
			[] => []
			[first, .. as rest] => Assembly.stage_plugin(
				first,
				external_dependencies,
			).concat(Assembly.stage_plugins(rest, external_dependencies))
		}

	plugin_dependency : Assembly.PluginSource -> Assembly.Dependency
	plugin_dependency = |declared_plugin| {
		name: declared_plugin.package_name,
		path: "../${declared_plugin.package_name}/main.roc",
	}

	app_dependency : Assembly.PluginSource -> Assembly.Dependency
	app_dependency = |declared_plugin| {
		name: declared_plugin.package_name,
		path: "./${declared_plugin.package_name}/main.roc",
	}

	render_app :
		Str, List(Assembly.SourceBundle), List(Assembly.PluginSource) -> Str
	render_app = |platform_url, bundles, plugins| {
		dependencies = Assembly.bundle_dependencies(bundles).concat(
			plugins.map(Assembly.app_dependency),
		)
		dependency_lines = dependencies.map(
			|dependency| "\t${dependency.name}: \"${dependency.path}\",",
		)
		import_lines = Assembly.bundle_imports(bundles).concat(
			plugins.map_with_index(
				|declared_plugin, index|
					Str.join_with(
						[
							"import ",
							declared_plugin.package_name,
							".",
							declared_plugin.module_name,
							" as Plugin",
							U64.to_str(index),
						],
						"",
					),
			),
		)
		registry_lines = plugins.map_with_index(
			|_, index| "\tPlugin${U64.to_str(index)}.plugin,",
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

	validate_plugin_files : List(Assembly.PluginFile) -> Try(
		{},
		Assembly.AssemblyProblem,
	)
	validate_plugin_files = |files|
		match files {
			[] => Ok({})
			[first, .. as rest] => {
				Assembly.validate_module_filename(first.filename)?
				Assembly.validate_plugin_files(rest)
			}
		}

	validate_plugins : List(Assembly.PluginSource) -> Try(
		{},
		Assembly.AssemblyProblem,
	)
	validate_plugins = |plugins|
		match plugins {
			[] => Ok({})
			[first, .. as rest] => {
				Assembly.validate_module_filename(first.module_source.filename)?
				Assembly.validate_plugin_files(first.schemas)?
				Assembly.validate_plugin_files(first.backends)?
				Assembly.validate_plugin_files(first.implementations)?
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
		List(Assembly.PluginSource) -> Try(
			Assembly.BuildPlan,
			Assembly.AssemblyProblem,
		)
	assemble = |profile, custom_plugins| {
		plugins = custom_plugins.concat(profile.embedded_plugins)
		Assembly.validate_plugins(plugins)?
		embedded_dependencies = profile.embedded_plugins.map(
			Assembly.plugin_dependency,
		)
		staged_custom_plugins = Assembly.stage_plugins(
			custom_plugins,
			embedded_dependencies,
		)
		staged_embedded_plugins = Assembly.stage_plugins(
			profile.embedded_plugins,
			[],
		)
		assembled_app_source = Assembly.render_app(
			profile.platform_url,
			profile.bundles,
			plugins,
		)
		assembled_files = Assembly.bundle_files(profile.bundles)
			.concat(staged_custom_plugins)
			.concat(staged_embedded_plugins)
		Assembly.validate_destinations(
			assembled_files.concat([
				{ destination: "main.roc", contents: assembled_app_source },
			]),
			[],
		)?
		Ok({ app_source: assembled_app_source, files: assembled_files })
	}
}
