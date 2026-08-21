app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Random
import pf.Stdout

import Cli

import "Executor.roc" as executor_source : Str
import "package.roc" as package_source : Str
import "parser/Body.roc" as body_source : Str
import "parser/Bytes.roc" as bytes_source : Str
import "parser/Config.roc" as config_source : Str
import "parser/main.roc" as parser_package_source : Str
import "Plugin.roc" as plugin_source : Str
import "../plugins/std/StdPlugin.roc" as std_plugin_source : Str
import "../plugins/std/backends/Nix.roc" as nix_backend_source : Str
import "../plugins/std/commands/Build.roc" as build_command_source : Str
import "../plugins/std/commands/Shell.roc" as shell_command_source : Str
import "../plugins/std/commands/Task.roc" as task_command_source : Str
import "../plugins/std/commands/Update.roc" as update_command_source : Str
import "../plugins/std/commands/Workflow.roc" as workflow_command_source : Str
import "../plugins/std/implementations/BuildNix.roc" as build_nix_source : Str
import "../plugins/std/implementations/ShellNix.roc" as shell_nix_source : Str
import "../plugins/std/implementations/TaskNix.roc" as task_nix_source : Str
import "../plugins/std/implementations/UpdateNix.roc" as update_nix_source : Str
import "../plugins/std/implementations/WorkflowNix.roc" as workflow_nix_source : Str
import "VERSION" as version_source : Str

platform_name = "FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn"

platform_url = "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/${platform_name}.tar.zst"

print_usage! : {} => Try({}, _)
print_usage! = |_| {
	Stdout.line!(Cli.usage)?
	Ok({})
}

plugin_parent : Str, Str -> Path
plugin_parent = |plugin_path, filename| {
	prefix = plugin_path.drop_suffix(filename)
	parent = if prefix == "/" {
		prefix
	} else {
		prefix.drop_suffix("/")
	}
	if parent.is_empty() Path.utf8(".") else Path.utf8(parent)
}

roc_files! : List(Path) => Try(List({ filename : Str, path : Path }), _)
roc_files! = |paths|
	match paths {
		[] => Ok([])
		[first, .. as rest] => {
			remaining = roc_files!(rest)?
			filename = (Path.filename(first) ?? first).display()
			if Path.is_file!(first)? and filename.ends_with(".roc") and filename != "main.roc" {
				Ok([{ filename, path: first }].concat(remaining))
			} else {
				Ok(remaining)
			}
		}
	}

stage_component! : Path, Path, Str, Str => Try({}, _)
stage_component! = |source_root, package_root, name, dependencies| {
	source_dir = Path.join(source_root, name)
	paths = if Path.is_dir!(source_dir)? Path.list!(source_dir)? else []
	files = roc_files!(paths)?

	target_dir = Path.join(package_root, name)
	Path.create_dir!(target_dir)?
	for file in files {
		Path.write_utf8!(
			Path.join(target_dir, file.filename),
			Path.read_utf8!(file.path)?,
		)?
	}

	modules = files.map(|file| file.filename.drop_suffix(".roc"))
	Path.write_utf8!(
		Path.join(target_dir, "main.roc"),
		"package [${Str.join_with(modules, ", ")}] { ${dependencies} }\n",
	)?
	Ok({})
}

build_stage! : Path, List(Str), Str, Path => Try({}, _)
build_stage! = |stage, plugin_paths, output_name, output_path| {
	Path.write_utf8!(Path.join(stage, "Executor.roc"), executor_source)?
	Path.write_utf8!(Path.join(stage, "package.roc"), package_source)?
	Path.write_utf8!(Path.join(stage, "Plugin.roc"), plugin_source)?
	Path.write_utf8!(Path.join(stage, "VERSION"), version_source)?

	parser_dir = Path.join(stage, "parser")
	Path.create_dir!(parser_dir)?
	Path.write_utf8!(Path.join(parser_dir, "Body.roc"), body_source)?
	Path.write_utf8!(Path.join(parser_dir, "Bytes.roc"), bytes_source)?
	Path.write_utf8!(Path.join(parser_dir, "Config.roc"), config_source)?
	Path.write_utf8!(Path.join(parser_dir, "main.roc"), parser_package_source)?

	std_dir = Path.join(stage, "std")
	Path.create_dir!(std_dir)?
	Path.write_utf8!(
		Path.join(std_dir, "main.roc"),
		"package [StdPlugin] { backends: \"./backends/main.roc\", commands: \"./commands/main.roc\", implementations: \"./implementations/main.roc\", kai: \"../package.roc\", parser: \"../parser/main.roc\" }\n",
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
		"package [Build, Shell, Task, Update, Workflow] { kai: \"../../package.roc\", parser: \"../../parser/main.roc\" }\n",
	)?
	Path.write_utf8!(Path.join(commands_dir, "Build.roc"), build_command_source)?
	Path.write_utf8!(Path.join(commands_dir, "Shell.roc"), shell_command_source)?
	Path.write_utf8!(Path.join(commands_dir, "Task.roc"), task_command_source)?
	Path.write_utf8!(Path.join(commands_dir, "Update.roc"), update_command_source)?
	Path.write_utf8!(Path.join(commands_dir, "Workflow.roc"), workflow_command_source)?

	implementations_dir = Path.join(std_dir, "implementations")
	Path.create_dir!(implementations_dir)?
	Path.write_utf8!(
		Path.join(implementations_dir, "main.roc"),
		"package [BuildNix, ShellNix, TaskNix, UpdateNix, WorkflowNix] { backends: \"../backends/main.roc\", commands: \"../commands/main.roc\", kai: \"../../package.roc\", parser: \"../../parser/main.roc\" }\n",
	)?
	Path.write_utf8!(Path.join(implementations_dir, "BuildNix.roc"), build_nix_source)?
	Path.write_utf8!(Path.join(implementations_dir, "ShellNix.roc"), shell_nix_source)?
	Path.write_utf8!(Path.join(implementations_dir, "TaskNix.roc"), task_nix_source)?
	Path.write_utf8!(Path.join(implementations_dir, "UpdateNix.roc"), update_nix_source)?
	Path.write_utf8!(Path.join(implementations_dir, "WorkflowNix.roc"), workflow_nix_source)?

	plugins = plugin_paths.map_with_index(|path, index| { index, path })
	for plugin in plugins {
		filename = (Path.filename(Path.utf8(plugin.path)) ?? Path.utf8(plugin.path)).display()
		module_name = filename.drop_suffix(".roc")
		package_name = "custom${U64.to_str(plugin.index)}"
		package_dir = Path.join(stage, package_name)
		Path.create_dir!(package_dir)?
		Path.write_utf8!(
			Path.join(package_dir, "main.roc"),
			"package [${module_name}] { backends: \"./backends/main.roc\", commands: \"./commands/main.roc\", implementations: \"./implementations/main.roc\", kai: \"../package.roc\", parser: \"../parser/main.roc\" }\n",
		)?
		Path.write_utf8!(
			Path.join(package_dir, filename),
			Path.read_utf8!(Path.utf8(plugin.path))?,
		)?

		source_root = plugin_parent(plugin.path, filename)
		stage_component!(
			source_root,
			package_dir,
			"commands",
			"kai: \"../../package.roc\", parser: \"../../parser/main.roc\"",
		)?
		stage_component!(
			source_root,
			package_dir,
			"backends",
			"kai: \"../../package.roc\"",
		)?
		stage_component!(
			source_root,
			package_dir,
			"implementations",
			"backends: \"../backends/main.roc\", commands: \"../commands/main.roc\", kai: \"../../package.roc\", parser: \"../../parser/main.roc\"",
		)?
	}

	dependencies = plugins.map(
		|plugin| {
			name = "custom${U64.to_str(plugin.index)}"
			"\t${name}: \"./${name}/main.roc\","
		},
	)
	import_lines = plugins.map(
		|plugin| {
			filename = (Path.filename(Path.utf8(plugin.path)) ?? Path.utf8(plugin.path)).display()
			module_name = filename.drop_suffix(".roc")
			"import custom${U64.to_str(plugin.index)}.${module_name} as Custom${U64.to_str(plugin.index)}"
		},
	)
	entries = plugins.map(|plugin| "\tCustom${U64.to_str(plugin.index)}.plugin,")

	app_source = Str.join_with(
		[
			"app [main!] {",
			"\tpf: platform \"${platform_url}\",",
			"\tkai: \"./package.roc\",",
			"\tstd: \"./std/main.roc\",",
		].concat(dependencies).concat([
			"}",
			"",
			"import Executor",
			"import std.StdPlugin",
		]).concat(import_lines).concat(
			[
				"",
				"registry = [",
			].concat(entries).concat([
				"\tStdPlugin.plugin,",
				"]",
				"",
				"main! = |args| Executor.run!(args, registry)",
			]),
		),
		"\n",
	)
	app_path = Path.join(stage, "main.roc")
	Path.write_utf8!(app_path, app_source)?
	Cmd.exec!(
		OsStr.utf8("roc"),
		["build", Path.display(app_path), "--opt=size", "--output=${output_name}"].map(OsStr.utf8),
	)?
	Cmd.exec!(OsStr.utf8("llvm-strip"), [Path.to_os_str(output_path)])?
	Cmd.exec!(Path.to_os_str(output_path), [OsStr.utf8("--xkai-validate-registry")])?
	Ok({})
}

build! : List(Str) => Try({}, _)
build! = |plugin_paths| {
	seed = Random.seed_u64!()?
	stage = Path.join(Env.temp_dir!(), "xkai-${U64.to_str(seed)}")
	cwd = Env.cwd!()?
	output_name = ".xkai-kai-${U64.to_str(seed)}"
	output_path = Path.join(cwd, output_name)
	published_path = Path.join(cwd, "kai")

	match Path.create_dir!(stage) {
		Err(err) => Err(err)
		Ok({}) =>
			match build_stage!(stage, plugin_paths, output_name, output_path) {
				Err(err) => {
					Path.delete_all!(stage) ?? {}
					Path.delete!(output_path) ?? {}
					Err(err)
				}
				Ok({}) =>
					match Path.delete_all!(stage) {
						Err(err) => {
							Path.delete!(output_path) ?? {}
							Err(err)
						}
						Ok({}) =>
							match Path.rename!(output_path, published_path) {
								Ok({}) => Ok({})
								Err(err) => {
									Path.delete!(output_path) ?? {}
									Err(err)
								}
							}
						}
				}
		}
}

main! : List(OsStr) => Try({}, _)
main! = |args| {
	display_args = args.drop_first(1).map(OsStr.display)
	match Cli.parse(display_args) {
		Cli.Command.Help => print_usage!({})
		Cli.Command.Version => {
			Stdout.line!("xkai version ${Cli.version}")?
			Ok({})
		}
		Cli.Command.Build(plugin_paths) => build!(plugin_paths)
		Cli.Command.Unknown(unknown) => {
			Stdout.line!("Unknown command ${unknown}")?
			print_usage!({})
		}
	}
}

## -- TESTS --

# Inputs -> expected commands:
# [] -> Help
# ["build"] -> Build([])
# ["build", "Example.roc"] -> Build(["Example.roc"])
# ["help"] -> Help
# ["version"] -> Version
# ["socrates"] -> Unknown("socrates")
expect Cli.check([], Cli.Command.Help)
expect Cli.check(["build"], Cli.Command.Build([]))
expect Cli.check(["build", "Example.roc"], Cli.Command.Build(["Example.roc"]))
expect Cli.check(["help"], Cli.Command.Help)
expect Cli.check(["version"], Cli.Command.Version)
expect Cli.check(["socrates"], Cli.Command.Unknown("socrates"))
expect Path.is_eq(plugin_parent("Plugin.roc", "Plugin.roc"), Path.utf8("."))
expect Path.is_eq(plugin_parent("/Plugin.roc", "Plugin.roc"), Path.utf8("/"))
expect Path.is_eq(plugin_parent("plugins/Plugin.roc", "Plugin.roc"), Path.utf8("plugins"))
