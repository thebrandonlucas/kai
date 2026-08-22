import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Random

import Assembly

Builder := [].{
	plugin_parent = |plugin_path, filename| {
		prefix = plugin_path.drop_suffix(filename)
		parent = if prefix == "/" {
			prefix
		} else {
			prefix.drop_suffix("/")
		}
		if parent.is_empty() Path.utf8(".") else Path.utf8(parent)
	}

	roc_files! = |paths|
		match paths {
			[] => Ok([])
			[first, .. as rest] => {
				remaining = Builder.roc_files!(rest)?
				filename = (Path.filename(first) ?? first).display()
				if Path.is_file!(first)? and filename.ends_with(".roc") and filename != "main.roc" {
					Ok([{ filename, path: first }].concat(remaining))
				} else {
					Ok(remaining)
				}
			}
		}

	load_files! = |files|
		match files {
			[] => Ok([])
			[first, .. as rest] => {
				contents = Path.read_utf8!(first.path)?
				remaining = Builder.load_files!(rest)?
				Ok([{ filename: first.filename, contents }].concat(remaining))
			}
		}

	load_component! = |source_root, name| {
		source_dir = Path.join(source_root, name)
		paths = if Path.is_dir!(source_dir)? Path.list!(source_dir)? else []
		Builder.load_files!(Builder.roc_files!(paths)?)
	}

	load_plugin! = |plugin_path| {
		path = Path.utf8(plugin_path)
		filename = (Path.filename(path) ?? path).display()
		source_root = Builder.plugin_parent(plugin_path, filename)
		Ok({
			filename,
			module_name: filename.drop_suffix(".roc"),
			contents: Path.read_utf8!(path)?,
			commands: Builder.load_component!(source_root, "commands")?,
			backends: Builder.load_component!(source_root, "backends")?,
			implementations: Builder.load_component!(source_root, "implementations")?,
		})
	}

	load_plugins! = |plugin_paths|
		match plugin_paths {
			[] => Ok([])
			[first, .. as rest] => {
				plugin = Builder.load_plugin!(first)?
				remaining = Builder.load_plugins!(rest)?
				Ok([plugin].concat(remaining))
			}
		}

	ensure_directories! = |root, parts|
		match parts {
			[] => Ok({})
			[first, .. as rest] => {
				directory = Path.join(root, first)
				if !Path.is_dir!(directory)? {
					Path.create_dir!(directory)?
				}
				Builder.ensure_directories!(directory, rest)
			}
		}

	write_source! = |stage, source| {
		Builder.ensure_directories!(stage, source.destination.split_on("/").drop_last(1))?
		Path.write_utf8!(Path.join(stage, source.destination), source.contents)
	}

	build_stage! = |stage, plan, output_name, output_path| {
		for source in plan.files {
			Builder.write_source!(stage, source)?
		}
		app_path = Path.join(stage, "main.roc")
		Path.write_utf8!(app_path, plan.app_source)?
		Cmd.exec!(
			OsStr.utf8("roc"),
			["build", Path.display(app_path), "--opt=size", "--output=${output_name}"].map(OsStr.utf8),
		)?
		Cmd.exec!(OsStr.utf8("llvm-strip"), [Path.to_os_str(output_path)])?
		Cmd.exec!(Path.to_os_str(output_path), [OsStr.utf8("--xkai-validate-registry")])?
		Ok({})
	}

	build! = |plugin_paths, profile| {
		plugins = Builder.load_plugins!(plugin_paths)?
		plan = Assembly.assemble(profile, plugins) ? |problem| InvalidAssembly(problem)
		seed = Random.seed_u64!()?
		stage = Path.join(Env.temp_dir!(), "xkai-${U64.to_str(seed)}")
		cwd = Env.cwd!()?
		output_name = ".xkai-kai-${U64.to_str(seed)}"
		output_path = Path.join(cwd, output_name)
		published_path = Path.join(cwd, "kai")

		match Path.create_dir!(stage) {
			Err(err) => Err(err)
			Ok({}) =>
				match Builder.build_stage!(stage, plan, output_name, output_path) {
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
}
