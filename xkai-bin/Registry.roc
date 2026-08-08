# Pure structural validation for plugin registries.
# validates all plugins in the registry.
# each of these plugins will be compiled into kai
import Body
import Plugin

Registry := [].{
	validate : List(Plugin.Plugin) -> List(Str)
	validate = |plugins| Registry.validate_plugins(plugins, 1)

	validate_plugins : List(Plugin.Plugin), U64 -> List(Str)
	validate_plugins = |plugins, index|
		match plugins {
			[] => []
			[first, .. as rest] => Registry.validate_plugin(first, index).concat(Registry.validate_plugins(rest, index + 1))
		}

	validate_plugin : Plugin.Plugin, U64 -> List(Str)
	validate_plugin = |plugin, index| {
		definition = Plugin.definition(plugin)
		name = if definition.name.is_empty() "#${U64.to_str(index)}" else "'${definition.name}'"
		errors = Registry.plugin_name_errors(name, definition.name)
			.concat(Registry.component_errors(name, definition))
			.concat(Registry.command_errors(name, definition.commands, []))
			.concat(Registry.backend_errors(name, definition.backends, []))
			.concat(Registry.implementation_errors(name, definition, definition.implementations, []))
			.concat(Registry.dangling_command_errors(name, definition.commands, definition.implementations))
			.concat(Registry.dangling_backend_errors(name, definition.backends, definition.implementations))
			.concat(Registry.default_backend_errors(name, definition.commands, definition.backends, definition.implementations))
		Registry.unique(errors, [])
	}

	diagnostic : Str, Str -> Str
	diagnostic = |plugin, message| "plugin ${plugin}: ${message}"

	plugin_name_errors : Str, Str -> List(Str)
	plugin_name_errors = |identity, name|
		if name.is_empty() [Registry.diagnostic(identity, "plugin name must not be empty")] else []

	component_errors : Str, Plugin.Definition -> List(Str)
	component_errors = |plugin, definition| {
		missing_commands = if definition.commands.is_empty() [Registry.diagnostic(plugin, "must define at least one command")] else []
		missing_backends = if definition.backends.is_empty() [Registry.diagnostic(plugin, "must define at least one backend")] else []
		missing_implementations = if definition.implementations.is_empty() [Registry.diagnostic(plugin, "must define at least one implementation")] else []
		missing_commands.concat(missing_backends).concat(missing_implementations)
	}

	command_errors : Str, List(Plugin.Command), List(Str) -> List(Str)
	command_errors = |plugin, commands, seen|
		match commands {
			[] => []
			[first, .. as rest] => {
				name_errors = if first.name.is_empty() [Registry.diagnostic(plugin, "command name must not be empty")] else []
				duplicate_errors = if Registry.contains(seen, first.name) [Registry.diagnostic(plugin, "duplicate command '${first.name}'")] else []
				body_errors = match first.body {
					Object(fields) => Registry.field_errors(plugin, first.name, fields, [])
				}
				name_errors.concat(duplicate_errors).concat(body_errors).concat(Registry.command_errors(plugin, rest, seen.append(first.name)))
			}
		}

	field_errors : Str, Str, List(Body.Field), List(Str) -> List(Str)
	field_errors = |plugin, command, fields, seen|
		match fields {
			[] => []
			[first, .. as rest] => {
				empty_errors = if first.name.is_empty() [Registry.diagnostic(plugin, "command '${command}' field name must not be empty")] else []
				invalid_errors = if first.name.is_empty() or Registry.valid_field_name(first.name) [] else [Registry.diagnostic(plugin, "command '${command}' field '${first.name}' must match [A-Za-z_][A-Za-z0-9_]*")]
				duplicate_errors = if Registry.contains(seen, first.name) [Registry.diagnostic(plugin, "command '${command}' has duplicate field '${first.name}'")] else []
				empty_errors.concat(invalid_errors).concat(duplicate_errors).concat(Registry.field_errors(plugin, command, rest, seen.append(first.name)))
			}
		}

	valid_field_name : Str -> Bool
	valid_field_name = |name| {
		bytes = name.to_utf8()
		match bytes {
			[] => Bool.False
			[first, .. as rest] => Registry.valid_name_start(first) and Registry.valid_name_rest(rest)
		}
	}

	valid_name_start : U8 -> Bool
	valid_name_start = |byte| (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95

	valid_name_rest : List(U8) -> Bool
	valid_name_rest = |bytes|
		match bytes {
			[] => Bool.True
			[first, .. as rest] => (Registry.valid_name_start(first) or (first >= 48 and first <= 57)) and Registry.valid_name_rest(rest)
		}

	backend_errors : Str, List(Plugin.Backend), List(Str) -> List(Str)
	backend_errors = |plugin, backends, seen|
		match backends {
			[] => []
			[first, .. as rest] => {
				name_errors = if first.name.is_empty() [Registry.diagnostic(plugin, "backend name must not be empty")] else []
				duplicate_errors = if Registry.contains(seen, first.name) [Registry.diagnostic(plugin, "duplicate backend '${first.name}'")] else []
				driver_errors = match first.determinate_system.driver {
					NoDriver => []
					Program(driver) => if driver.is_empty() [Registry.diagnostic(plugin, "backend '${first.name}' driver name must not be empty")] else []
				}
				required_package_errors = Registry.package_errors(plugin, first.name, first.required_packages)
				name_errors.concat(duplicate_errors).concat(driver_errors).concat(required_package_errors).concat(Registry.backend_errors(plugin, rest, seen.append(first.name)))
			}
		}

	package_errors : Str, Str, List(Plugin.Package) -> List(Str)
	package_errors = |plugin, backend, required_packages|
		match required_packages {
			[] => []
			[first, .. as rest] => {
				name_errors = if first.name.is_empty() [Registry.diagnostic(plugin, "backend '${backend}' package name must not be empty")] else []
				program_errors = if first.program.is_empty() [Registry.diagnostic(plugin, "backend '${backend}' package '${first.name}' program name must not be empty")] else []
				name_errors.concat(program_errors).concat(Registry.package_errors(plugin, backend, rest))
			}
		}

	implementation_errors : Str, Plugin.Definition, List(Plugin.Implementation), List({ backend : Str, command : Str }) -> List(Str)
	implementation_errors = |plugin, definition, implementations, seen|
		match implementations {
			[] => []
			[first, .. as rest] => {
				pair = { backend: first.backend, command: first.command }
				command_ref_errors = if Registry.has_command(definition.commands, first.command) [] else [Registry.diagnostic(plugin, "implementation '${first.command}/${first.backend}' references unknown command '${first.command}'")]
				backend_ref_errors = if Registry.has_backend(definition.backends, first.backend) [] else [Registry.diagnostic(plugin, "implementation '${first.command}/${first.backend}' references unknown backend '${first.backend}'")]
				duplicate_errors = if Registry.contains_pair(seen, pair) [Registry.diagnostic(plugin, "duplicate implementation '${first.command}/${first.backend}'")] else []
				command_ref_errors.concat(backend_ref_errors).concat(duplicate_errors).concat(Registry.implementation_errors(plugin, definition, rest, seen.append(pair)))
			}
		}

	dangling_command_errors : Str, List(Plugin.Command), List(Plugin.Implementation) -> List(Str)
	dangling_command_errors = |plugin, commands, implementations|
		match commands {
			[] => []
			[first, .. as rest] => {
				errors = if Registry.uses_command(implementations, first.name) [] else [Registry.diagnostic(plugin, "command '${first.name}' has no implementation")]
				errors.concat(Registry.dangling_command_errors(plugin, rest, implementations))
			}
		}

	dangling_backend_errors : Str, List(Plugin.Backend), List(Plugin.Implementation) -> List(Str)
	dangling_backend_errors = |plugin, backends, implementations|
		match backends {
			[] => []
			[first, .. as rest] => {
				errors = if Registry.uses_backend(implementations, first.name) [] else [Registry.diagnostic(plugin, "backend '${first.name}' has no implementation")]
				errors.concat(Registry.dangling_backend_errors(plugin, rest, implementations))
			}
		}

	default_backend_errors : Str, List(Plugin.Command), List(Plugin.Backend), List(Plugin.Implementation) -> List(Str)
	default_backend_errors = |plugin, commands, backends, implementations|
		match commands {
			[] => []
			[first, .. as rest] => {
				errors = if !Registry.has_backend(backends, first.default_backend) {
					[Registry.diagnostic(plugin, "command '${first.name}' default backend '${first.default_backend}' does not exist")]
				} else if !Registry.has_implementation(implementations, first.name, first.default_backend) {
					[Registry.diagnostic(plugin, "command '${first.name}' default backend '${first.default_backend}' does not implement the command")]
				} else {
					[]
				}
				errors.concat(Registry.default_backend_errors(plugin, rest, backends, implementations))
			}
		}

	unique : List(Str), List(Str) -> List(Str)
	unique = |values, seen|
		match values {
			[] => []
			[first, .. as rest] =>
				if Registry.contains(seen, first) {
					Registry.unique(rest, seen)
				} else {
					[first].concat(Registry.unique(rest, seen.append(first)))
				}
			}

	contains : List(Str), Str -> Bool
	contains = |values, target|
		match values {
			[] => Bool.False
			[first, .. as rest] => first == target or Registry.contains(rest, target)
		}

	contains_pair : List({ backend : Str, command : Str }), { backend : Str, command : Str } -> Bool
	contains_pair = |pairs, target|
		match pairs {
			[] => Bool.False
			[first, .. as rest] => first == target or Registry.contains_pair(rest, target)
		}

	has_command : List(Plugin.Command), Str -> Bool
	has_command = |commands, target|
		match commands {
			[] => Bool.False
			[first, .. as rest] => first.name == target or Registry.has_command(rest, target)
		}

	has_backend : List(Plugin.Backend), Str -> Bool
	has_backend = |backends, target|
		match backends {
			[] => Bool.False
			[first, .. as rest] => first.name == target or Registry.has_backend(rest, target)
		}

	uses_command : List(Plugin.Implementation), Str -> Bool
	uses_command = |implementations, target|
		match implementations {
			[] => Bool.False
			[first, .. as rest] => first.command == target or Registry.uses_command(rest, target)
		}

	uses_backend : List(Plugin.Implementation), Str -> Bool
	uses_backend = |implementations, target|
		match implementations {
			[] => Bool.False
			[first, .. as rest] => first.backend == target or Registry.uses_backend(rest, target)
		}

	has_implementation : List(Plugin.Implementation), Str, Str -> Bool
	has_implementation = |implementations, command_name, backend_name|
		match implementations {
			[] => Bool.False
			[first, .. as rest] => (first.command == command_name and first.backend == backend_name) or Registry.has_implementation(rest, command_name, backend_name)
		}
}
