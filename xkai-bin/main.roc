app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Random
import pf.Stderr
import pf.Stdout

import Cli

import "Body.roc" as body_source : Str
import "Executor.roc" as executor_source : Str
import "package.roc" as package_source : Str
import "Plugin.roc" as plugin_source : Str
import "Registry.roc" as registry_source : Str
import "../plugins/StdPlugin.roc" as std_plugin_source : Str
import "../plugins/backends/Nix.roc" as nix_backend_source : Str
import "../plugins/commands/Shell.roc" as shell_command_source : Str
import "../plugins/implementations/ShellNix.roc" as shell_nix_source : Str
import "VERSION" as version_source : Str

# FIXME: assuming this shouldn't be hardcoded?
platform_name = "FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn"

platform_url = "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/${platform_name}.tar.zst"

print_usage! : {} => Try({}, [Exit(I32)])
print_usage! = |_| {
	Stdout.line!(Cli.usage) ? |_| Exit(1)
	Ok({})
}

fail! : Str => Try({}, [Exit(I32)])
fail! = |message| {
	Stderr.line!(message) ?? {}
	Err(Exit(1))
}

SourceFile : { filename : Str, module_name : Str, source : Str }

SourceDirectory := [Directory({ children : List(SourceDirectory), name : Str, sources : List(SourceFile) })]

ComponentTree : { name : Str, root : SourceDirectory }

PluginTree : { components : List(ComponentTree), top : SourceFile }

parent_u8 : List(U8), Bool -> List(U8)
parent_u8 = |units, allow_backslash|
	match List.find_last_index(units, |unit| unit == 47 or (allow_backslash and unit == 92)) {
		Err(NotFound) => [46]
		Ok(index) => {
			keep_separator = index == 0 or (index == 2 and (units.get(1) ?? 0) == 58)
			List.sublist(units, { start: 0, len: if keep_separator index + 1 else index })
		}
	}

parent_u16 : List(U16) -> List(U16)
parent_u16 = |units|
	match List.find_last_index(units, |unit| unit == 47 or unit == 92) {
		Err(NotFound) => [46]
		Ok(index) => {
			keep_separator = index == 0 or (index == 2 and (units.get(1) ?? 0) == 58)
			List.sublist(units, { start: 0, len: if keep_separator index + 1 else index })
		}
	}

path_parent : Path -> Path
path_parent = |path|
	match Path.to_raw(path) {
		Utf8(str) => Path.utf8(Str.from_utf8(parent_u8(Str.to_utf8(str), Bool.True)) ?? ".")
		UnixBytes(bytes) => Path.unix_bytes(parent_u8(bytes, Bool.False))
		WindowsU16s(units) => Path.windows_u16s(parent_u16(units))
	}

has_parent_reference : Str -> Bool
has_parent_reference = |path|
	path == ".." or
		path.starts_with("../") or
			path.contains("/../") or
				path.ends_with("/..") or
					path.starts_with("..\\") or
						path.contains("\\..\\") or
							path.ends_with("\\..")

validate_ancestors! : Path => Try({}, [InvalidPlugin(Str)])
validate_ancestors! = |path| {
	parent = path_parent(path)
	if Path.is_eq(path, parent) {
		Ok({})
	} else {
		match inspect_type!(path)? {
			IsSymLink => Err(InvalidPlugin("plugin paths cannot traverse symlinks: ${Path.display(path)}"))
			_ => validate_ancestors!(parent)
		}
	}
}

path_filename : Path -> Try(Str, [InvalidPlugin(Str)])
path_filename = |path|
	match Path.filename(path) {
		Err(_) => Err(InvalidPlugin("plugin paths must name files"))
		Ok(filename) =>
			match Path.to_str(filename) {
				Err(_) => Err(InvalidPlugin("plugin source filenames must be valid text"))
				Ok(str) => Ok(str)
			}
		}

first_line_is_package : List(Str) -> Bool
first_line_is_package = |lines|
	match lines {
		[] => Bool.False
		[first, .. as rest] => {
			line = first.trim()
			if line.is_empty() or line.starts_with("#") {
				first_line_is_package(rest)
			} else {
				line == "package" or line.starts_with("package ") or line.starts_with("package\t")
			}
		}
	}

inspect_type! : Path => Try([IsFile, IsDir, IsSymLink], [InvalidPlugin(Str)])
inspect_type! = |path|
	match Path.type!(path) {
		Ok(path_type) => Ok(path_type)
		Err(_) => Err(InvalidPlugin("cannot inspect plugin path: ${Path.display(path)}"))
	}

list_directory! : Path => Try(List(Path), [InvalidPlugin(Str)])
list_directory! = |path|
	match Path.list!(path) {
		Ok(entries) => Ok(entries)
		Err(_) => Err(InvalidPlugin("cannot list plugin directory: ${Path.display(path)}"))
	}

read_source! : Path, Str => Try(SourceFile, [InvalidPlugin(Str)])
read_source! = |path, filename|
	match Path.is_readable!(path) {
		Err(_) => Err(InvalidPlugin("cannot inspect plugin source readability: ${Path.display(path)}"))
		Ok(Bool.False) => Err(InvalidPlugin("unreadable plugin source: ${Path.display(path)}"))
		Ok(Bool.True) =>
			match Path.read_utf8!(path) {
				Err(_) => Err(InvalidPlugin("plugin source must be readable UTF-8: ${Path.display(path)}"))
				Ok(source) =>
					if first_line_is_package(source.split_on("\n")) {
						Err(InvalidPlugin("plugin sources cannot define package manifests: ${Path.display(path)}"))
					} else {
						Ok({ filename, module_name: filename.drop_suffix(".roc"), source })
					}
				}
		}

root_has_manifest : List(Path) -> Try(Bool, _)
root_has_manifest = |entries|
	match entries {
		[] => Ok(Bool.False)
		[first, .. as rest] =>
			if path_filename(first)? == "main.roc" {
				Ok(Bool.True)
			} else {
				root_has_manifest(rest)
			}
		}

discover_directory! : Path, Str => Try(SourceDirectory, _)
discover_directory! = |directory, name| {
	contents = discover_entries!(list_directory!(directory)?)?
	module_names = contents.sources.map(|source| source.module_name)
	if has_duplicate(module_names, []) {
		Err(InvalidPlugin("plugin directory contains duplicate module names: ${Path.display(directory)}"))
	} else {
		Ok(SourceDirectory.Directory({ children: contents.children, name, sources: contents.sources }))
	}
}

discover_entries! : List(Path) => Try({ children : List(SourceDirectory), sources : List(SourceFile) }, _)
discover_entries! = |entries|
	match entries {
		[] => Ok({ children: [], sources: [] })
		[first, .. as rest] => {
			filename = path_filename(first)?
			remaining = discover_entries!(rest)?
			match inspect_type!(first)? {
				IsSymLink => Err(InvalidPlugin("plugin component entries cannot be symlinks: ${Path.display(first)}"))
				IsDir => Ok({
					children: [discover_directory!(first, filename)?].concat(remaining.children),
					sources: remaining.sources,
				})
				IsFile =>
					if filename.ends_with(".roc") {
						if filename == "main.roc" {
							Err(InvalidPlugin("main.roc is reserved for generated component manifests"))
						} else {
							Ok({
								children: remaining.children,
								sources: [read_source!(first, filename)?].concat(remaining.sources),
							})
						}
					} else {
						Ok(remaining)
					}
				}
		}
	}

discover_component! : Path, Str => Try([Absent, Present(ComponentTree)], _)
discover_component! = |root, name| {
	directory = Path.join(root, name)
	match Path.type!(directory) {
		Err(PathErr(NotFound)) => Ok(Absent)
		Err(_) => Err(InvalidPlugin("cannot inspect plugin component path: ${Path.display(directory)}"))
		Ok(IsSymLink) => Err(InvalidPlugin("plugin component paths cannot be symlinks: ${Path.display(directory)}"))
		Ok(IsFile) => Err(InvalidPlugin("plugin component path must be a directory: ${Path.display(directory)}"))
		Ok(IsDir) => Ok(Present({ name, root: discover_directory!(directory, name)? }))
	}
}

discover_components! : Path, List(Str) => Try(List(ComponentTree), _)
discover_components! = |root, names|
	match names {
		[] => Ok([])
		[first, .. as rest] => {
			remaining = discover_components!(root, rest)?
			match discover_component!(root, first)? {
				Absent => Ok(remaining)
				Present(component) => Ok([component].concat(remaining))
			}
		}
	}

contains_name : List(Str), Str -> Bool
contains_name = |names, target|
	match names {
		[] => Bool.False
		[first, .. as rest] => first == target or contains_name(rest, target)
	}

has_duplicate : List(Str), List(Str) -> Bool
has_duplicate = |names, seen|
	match names {
		[] => Bool.False
		[first, .. as rest] => contains_name(seen, first) or has_duplicate(rest, seen.append(first))
	}

discover_plugin! : Path => Try(PluginTree, _)
discover_plugin! = |top_path| {
	filename = path_filename(top_path)?
	path_text = Path.to_str(top_path) ? |_| InvalidPlugin("plugin paths must be valid text")
	if !filename.ends_with(".roc") or filename == ".roc" {
		Err(InvalidPlugin("plugin top-level path must end in .roc"))
	} else if filename == "main.roc" {
		Err(InvalidPlugin("main.roc is reserved for the generated plugin manifest"))
	} else if has_parent_reference(path_text) {
		Err(InvalidPlugin("plugin paths cannot contain '..' components"))
	} else {
		match inspect_type!(top_path)? {
			IsSymLink => Err(InvalidPlugin("plugin top-level paths cannot be symlinks: ${Path.display(top_path)}"))
			IsDir => Err(InvalidPlugin("plugin top-level path must be a .roc file"))
			IsFile => {
				root = path_parent(top_path)
				validate_ancestors!(root)?
				match inspect_type!(root)? {
					IsSymLink => Err(InvalidPlugin("plugin root cannot be a symlink: ${Path.display(root)}"))
					IsFile => Err(InvalidPlugin("plugin root must be a directory: ${Path.display(root)}"))
					IsDir => {
						if root_has_manifest(list_directory!(root)?)? {
							Err(InvalidPlugin("plugin root conflicts with generated main.roc manifest"))
						} else {
							Ok({
								components: discover_components!(root, ["commands", "backends", "implementations"])?,
								top: read_source!(top_path, filename)?,
							})
						}
					}
				}
			}
		}
	}
}

discover_plugins! : List(Path) => Try(List(PluginTree), _)
discover_plugins! = |paths|
	match paths {
		[] => Ok([])
		[first, .. as rest] => Ok([discover_plugin!(first)?].concat(discover_plugins!(rest)?))
	}

has_component : List(ComponentTree), Str -> Bool
has_component = |components, name|
	match components {
		[] => Bool.False
		[first, .. as rest] => first.name == name or has_component(rest, name)
	}

manifest : List(Str), List(Str) -> Str
manifest = |modules, dependencies|
	"package [${Str.join_with(modules, ", ")}] { ${Str.join_with(dependencies, ", ")} }\n"

source_directory_name : SourceDirectory -> Str
source_directory_name = |directory|
	match directory {
		SourceDirectory.Directory({ children: _, name, sources: _ }) => name
	}

stage_directory! : Path, SourceDirectory, Str, List(ComponentTree), Str => Try({}, _)
stage_directory! = |path, directory, component_name, components, sibling_prefix|
	match directory {
		SourceDirectory.Directory({ children, name: _, sources }) => {
			Path.create_dir!(path)?
			child_dependencies = children.map(
				|child| "${source_directory_name(child)}: \"./${source_directory_name(child)}/main.roc\"",
			)
			dependencies = if component_name == "implementations" {
				child_dependencies
					.concat(if has_component(components, "backends") ["backends: \"${sibling_prefix}/backends/main.roc\""] else [])
					.concat(if has_component(components, "commands") ["commands: \"${sibling_prefix}/commands/main.roc\""] else [])
			} else {
				child_dependencies
			}
			Path.write_utf8!(
				Path.join(path, "main.roc"),
				manifest(sources.map(|source| source.module_name), dependencies.append("kai: \"${sibling_prefix}/../package.roc\"")),
			)?
			for source in sources {
				Path.write_utf8!(Path.join(path, source.filename), source.source)?
			}
			for child in children {
				stage_directory!(Path.join(path, source_directory_name(child)), child, component_name, components, "${sibling_prefix}/..")?
			}
			Ok({})
		}
	}

stage_plugin! : Path, PluginTree => Try({}, _)
stage_plugin! = |package_dir, plugin| {
	Path.create_dir!(package_dir)?
	top_dependencies = plugin.components.map(|component| "${component.name}: \"./${component.name}/main.roc\"")
		.append("kai: \"../package.roc\"")
	Path.write_utf8!(Path.join(package_dir, "main.roc"), manifest([plugin.top.module_name], top_dependencies))?
	Path.write_utf8!(Path.join(package_dir, plugin.top.filename), plugin.top.source)?

	for component in plugin.components {
		stage_directory!(Path.join(package_dir, component.name), component.root, component.name, plugin.components, "..")?
	}
	Ok({})
}

output_arg : Path -> OsStr
output_arg = |path|
	match Path.to_raw(path) {
		Utf8(str) => OsStr.utf8("--output=${str}")
		UnixBytes(bytes) => OsStr.unix_bytes(Str.to_utf8("--output=").concat(bytes))
		WindowsU16s(units) => OsStr.windows_u16s([45, 45, 111, 117, 116, 112, 117, 116, 61].concat(units))
	}

build_stage! : Path, Path, List(PluginTree) => Try({}, _)
build_stage! = |stage, output_path, plugin_trees| {
	Path.write_utf8!(Path.join(stage, "Body.roc"), body_source)?
	Path.write_utf8!(Path.join(stage, "Executor.roc"), executor_source)?
	Path.write_utf8!(Path.join(stage, "package.roc"), package_source)?
	Path.write_utf8!(Path.join(stage, "Plugin.roc"), plugin_source)?
	Path.write_utf8!(Path.join(stage, "Registry.roc"), registry_source)?
	Path.write_utf8!(Path.join(stage, "VERSION"), version_source)?

	std_dir = Path.join(stage, "std")
	Path.create_dir!(std_dir)?
	Path.write_utf8!(
		Path.join(std_dir, "main.roc"),
		"package [StdPlugin] { backends: \"./backends/main.roc\", commands: \"./commands/main.roc\", implementations: \"./implementations/main.roc\", kai: \"../package.roc\" }\n",
	)?
	Path.write_utf8!(Path.join(std_dir, "StdPlugin.roc"), std_plugin_source)?

	backends_dir = Path.join(std_dir, "backends")
	Path.create_dir!(backends_dir)?
	Path.write_utf8!(
		Path.join(backends_dir, "main.roc"),
		"package [Nix] { kai: \"../../package.roc\" }\n",
	)?
	Path.write_utf8!(Path.join(backends_dir, "Nix.roc"), nix_backend_source)?

	commands_dir = Path.join(std_dir, "commands")
	Path.create_dir!(commands_dir)?
	Path.write_utf8!(
		Path.join(commands_dir, "main.roc"),
		"package [Shell] { kai: \"../../package.roc\" }\n",
	)?
	Path.write_utf8!(Path.join(commands_dir, "Shell.roc"), shell_command_source)?

	implementations_dir = Path.join(std_dir, "implementations")
	Path.create_dir!(implementations_dir)?
	Path.write_utf8!(
		Path.join(implementations_dir, "main.roc"),
		"package [ShellNix] { backends: \"../backends/main.roc\", commands: \"../commands/main.roc\", kai: \"../../package.roc\" }\n",
	)?
	Path.write_utf8!(Path.join(implementations_dir, "ShellNix.roc"), shell_nix_source)?

	plugins = plugin_trees.map_with_index(|tree, index| { index, tree })
	for plugin in plugins {
		stage_plugin!(Path.join(stage, "custom${U64.to_str(plugin.index)}"), plugin.tree)?
	}

	dependencies = plugins.map(|plugin| "\tcustom${U64.to_str(plugin.index)}: \"./custom${U64.to_str(plugin.index)}/main.roc\",")
	import_lines = plugins.map(|plugin| "import custom${U64.to_str(plugin.index)}.${plugin.tree.top.module_name} as Custom${U64.to_str(plugin.index)}")
	entries = plugins.map(|plugin| "\tCustom${U64.to_str(plugin.index)}.plugin,")
	app_header = [
		"app [main!] {",
		"\tpf: platform \"${platform_url}\",",
		"\tkai: \"./package.roc\",",
		"\tstd: \"./std/main.roc\",",
	].concat(dependencies).concat(["}"])
	registry_lines = ["", "registry = ["].concat(entries).concat(["\tStdPlugin.plugin,", "]"])

	validator_source = Str.join_with(
		app_header.concat([
			"",
			"import pf.OsStr",
			"import pf.Stderr",
			"import kai.Registry",
			"import std.StdPlugin",
		]).concat(import_lines).concat(registry_lines).concat([
			"",
			"print_errors! = |errors|",
			"\tmatch errors {",
			"\t\t[] => Ok({})",
			"\t\t[first, .. as rest] => {",
			"\t\t\tStderr.line!(first) ? |_| Exit(1)",
			"\t\t\tprint_errors!(rest)",
			"\t\t}",
			"\t}",
			"",
			"main! = |args|",
			"\tif args.drop_first(1).map(OsStr.display) == [\"--validate\"] {",
			"\t\terrors = Registry.validate(registry)",
			"\t\tif errors.is_empty() {",
			"\t\t\tOk({})",
			"\t\t} else {",
			"\t\t\tprint_errors!(errors)?",
			"\t\t\tErr(Exit(1))",
			"\t\t}",
			"\t} else {",
			"\t\tOk({})",
			"\t}",
		]),
		"\n",
	)
	validator_path = Path.join(stage, "validator.roc")
	validator_output = Path.join(stage, "registry-validator")
	Path.write_utf8!(validator_path, validator_source)?
	Cmd.exec!(OsStr.utf8("roc"), [OsStr.utf8("build"), Path.to_os_str(validator_path), OsStr.utf8("--opt=dev"), output_arg(validator_output)])?
	Cmd.exec!(Path.to_os_str(validator_output), [OsStr.utf8("--validate")])?

	app_source = Str.join_with(
		app_header.concat(["", "import Executor", "import std.StdPlugin"]).concat(import_lines).concat(registry_lines).concat(["", "main! = |args| Executor.run!(args, registry)"]),
		"\n",
	)
	app_path = Path.join(stage, "main.roc")
	Path.write_utf8!(app_path, app_source)?
	Cmd.exec!(OsStr.utf8("roc"), [OsStr.utf8("build"), Path.to_os_str(app_path), OsStr.utf8("--opt=size"), output_arg(output_path)])?
	Cmd.exec!(OsStr.utf8("llvm-strip"), [Path.to_os_str(output_path)])?
	Ok({})
}

build! : List(Path) => Try({}, [InvalidPlugin(Str)])
build! = |plugin_paths| {
	plugins = discover_plugins!(plugin_paths)?
	seed = Random.seed_u64!() ? |_| InvalidPlugin("cannot create plugin build identifier")
	cwd = Env.cwd!() ? |_| InvalidPlugin("cannot determine output directory")
	stage = Path.join(Env.temp_dir!(), "xkai-${U64.to_str(seed)}")
	output = Path.join(cwd, ".xkai-output-${U64.to_str(seed)}")
	Path.create_dir!(stage) ? |_| InvalidPlugin("cannot create temporary plugin build directory")
	match build_stage!(stage, output, plugins) {
		Err(_) => {
			Path.delete!(output) ?? {}
			Path.delete_all!(stage) ?? {}
			Err(InvalidPlugin("plugin build failed"))
		}
		Ok({}) =>
			match Path.delete_all!(stage) {
				Err(_) => {
					Path.delete!(output) ?? {}
					Err(InvalidPlugin("cannot remove temporary plugin build directory"))
				}
				Ok({}) =>
					match Path.rename!(output, Path.join(cwd, "kai")) {
						Ok({}) => Ok({})
						Err(_) => {
							Path.delete!(output) ?? {}
							Err(InvalidPlugin("cannot install built kai executable"))
						}
					}
				}
		}
}

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	display_args = args.drop_first(1).map(OsStr.display)
	match Cli.parse(display_args) {
		Cli.Command.Help => print_usage!({})
		Cli.Command.Version => {
			Stdout.line!("xkai version ${Cli.version}") ? |_| Exit(1)
			Ok({})
		}
		Cli.Command.Build(_) =>
			match build!(args.drop_first(2).map(Path.from_os_str)) {
				Ok({}) => Ok({})
				Err(InvalidPlugin(message)) => fail!(message)
			}
		Cli.Command.Unknown(unknown) => {
			Stdout.line!("Unknown command ${unknown}") ? |_| Exit(1)
			print_usage!({})
		}
	}
}

## -- TESTS --

expect Cli.check([], Cli.Command.Help)
expect Cli.check(["build"], Cli.Command.Build([]))
expect Cli.check(["build", "Example.roc"], Cli.Command.Build(["Example.roc"]))
expect Cli.check(["help"], Cli.Command.Help)
expect Cli.check(["version"], Cli.Command.Version)
expect Cli.check(["socrates"], Cli.Command.Unknown("socrates"))
