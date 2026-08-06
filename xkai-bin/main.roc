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
import "Plugin.roc" as plugin_source : Str
import "../plugins/StdPlugin.roc" as std_plugin_source : Str
import "VERSION" as version_source : Str

platform_name = "FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn"

platform_url = "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/${platform_name}.tar.zst"

print_usage! : {} => Try({}, _)
print_usage! = |_| {
	Stdout.line!(Cli.usage)?
	Ok({})
}

build_stage! : Path, List(Str) => Try({}, _)
build_stage! = |stage, plugin_paths| {
	Path.write_utf8!(Path.join(stage, "Executor.roc"), executor_source)?
	Path.write_utf8!(Path.join(stage, "package.roc"), package_source)?
	Path.write_utf8!(Path.join(stage, "Plugin.roc"), plugin_source)?
	Path.write_utf8!(Path.join(stage, "VERSION"), version_source)?

	std_dir = Path.join(stage, "std")
	Path.create_dir!(std_dir)?
	Path.write_utf8!(
		Path.join(std_dir, "main.roc"),
		"package [StdPlugin] { kai: \"../package.roc\" }\n",
	)?
	Path.write_utf8!(Path.join(std_dir, "StdPlugin.roc"), std_plugin_source)?

	plugins = plugin_paths.map_with_index(|path, index| { index, path })
	for plugin in plugins {
		filename = (Path.filename(Path.utf8(plugin.path)) ?? Path.utf8(plugin.path)).display()
		module_name = filename.drop_suffix(".roc")
		package_name = "custom${U64.to_str(plugin.index)}"
		package_dir = Path.join(stage, package_name)
		Path.create_dir!(package_dir)?
		Path.write_utf8!(
			Path.join(package_dir, "main.roc"),
			"package [${module_name}] { kai: \"../package.roc\" }\n",
		)?
		Path.write_utf8!(
			Path.join(package_dir, filename),
			Path.read_utf8!(Path.utf8(plugin.path))?,
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
		["build", Path.display(app_path), "--opt=size", "--output=kai"].map(OsStr.utf8),
	)?
	Cmd.exec!(OsStr.utf8("llvm-strip"), [OsStr.utf8("kai")])?
	Ok({})
}

build! : List(Str) => Try({}, _)
build! = |plugin_paths| {
	seed = Random.seed_u64!()?
	stage = Path.join(Env.temp_dir!(), "xkai-${U64.to_str(seed)}")
	Path.create_dir!(stage)?

	match build_stage!(stage, plugin_paths) {
		Ok({}) => Path.delete_all!(stage)
		Err(err) => {
			Path.delete_all!(stage) ?? {}
			Err(err)
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

expect Cli.check([], Cli.Command.Help)
expect Cli.check(["build"], Cli.Command.Build([]))
expect Cli.check(["build", "Example.roc"], Cli.Command.Build(["Example.roc"]))
expect Cli.check(["help"], Cli.Command.Help)
expect Cli.check(["version"], Cli.Command.Version)
expect Cli.check(["socrates"], Cli.Command.Unknown("socrates"))
