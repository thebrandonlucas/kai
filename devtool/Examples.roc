# Run Kaifile examples
import pf.Path
import pf.Stdout

import parser.Fields
import parser.Blocks
import kai.Plugin
import std.StdPlugin

Examples := [].{
	Invocation := {
		arch : Plugin.HostArch,
		args : List(Str),
		os : Plugin.HostOs,
	}

	run! = |directory| {
		root = Path.utf8(directory)
		if !Path.is_dir!(root)? {
			Err(ExamplesDirectoryRequired(directory))
		} else {
			kaifiles = Examples.discover!(root)?
			if kaifiles.is_empty() {
				Err(NoKaifilesFound(directory))
			} else {
				for kaifile in kaifiles {
					Examples.check_file!(kaifile)?
				}
				Stdout.line!("tested ${U64.to_str(kaifiles.len())} Kaifile examples")?
				Ok({})
			}
		}
	}

	discover! = |path| {
		if Path.is_sym_link!(path)? {
			Ok([])
		} else if Path.is_dir!(path)? {
			Examples.discover_entries!(Path.list!(path)?)
		} else if
			Path.is_file!(path)? and
				Path.display(Path.filename(path) ?? path) == "Kaifile"
				{
					Ok([path])
				} else {
					Ok([])
				}
	}

	discover_entries! = |entries|
		match entries {
			[] => Ok([])
			[first, .. as rest] => {
				found = Examples.discover!(first)?
				remaining = Examples.discover_entries!(rest)?
				Ok(found.concat(remaining))
			}
		}

	check_file! = |kaifile| {
		path = Path.display(kaifile)
		source = Path.read_utf8!(kaifile)?
		blocks = Blocks.scan(source) ? |diagnostic|
			InvalidExampleConfig({ diagnostic: Str.inspect(diagnostic), path })
		checks = Examples.invocations(blocks, path)?
		if checks.is_empty() {
			Err(EmptyKaifileExample(path))
		} else {
			Examples.check_invocations(source, path, checks)?
			Stdout.line!("tested: ${path}")
		}
	}

	invocations : List(Blocks.Block), Str -> Try(List(Examples.Invocation), _)
	invocations = |blocks, path|
		Examples.collect_blocks(
			blocks,
			path,
			LINUX,
			X64,
			Bool.True,
		)

	collect_blocks :
		List(Blocks.Block),
		Str,
		Plugin.HostOs,
		Plugin.HostArch,
		Bool ->
			Try(
				List(Examples.Invocation),
				_,
			)
	collect_blocks = |blocks, path, os, arch, allow_hosts|
		match blocks {
			[] => Ok([])
			[first, .. as rest] => {
				current_result = match first.header {
					["nixpkgs", _] | ["nixpkgs", _, _] => Ok([])
					["source", _] | ["source", _, _] => Ok([])
					_ => if allow_hosts {
						match first.header {
							["on", "linux"] => Examples.nested_invocations(first, path, LINUX, X64)
							["on", "macos"] => Examples.nested_invocations(
								first,
								path,
								MACOS,
								AARCH64,
							)
							["on", host] => Err(UnsupportedExampleHost({ host, path }))
							_ => Examples.invocation_for_header(
								first.header,
								path,
								os,
								arch,
							).map_ok(|invocation| [invocation])
						}
					} else {
						Examples.invocation_for_header(
							first.header,
							path,
							os,
							arch,
						).map_ok(|invocation| [invocation])
					}
				}
				current = current_result?
				remaining = Examples.collect_blocks(rest, path, os, arch, allow_hosts)?
				Ok(current.concat(remaining))
			}
		}

	nested_invocations = |host_block, path, os, arch| {
		blocks = Blocks.scan(host_block.body) ? |diagnostic|
			InvalidExampleHostConfig({ diagnostic: Str.inspect(diagnostic), path })
		Examples.collect_blocks(blocks, path, os, arch, Bool.False)
	}

	invocation_for_header :
		List(Str), Str, Plugin.HostOs, Plugin.HostArch -> Try(Examples.Invocation, _)
	invocation_for_header = |header, path, os, arch| {
		args = match header {
			["shell"] => Ok(["shell"])
			["shell", backend] => Ok(["shell", backend])
			["environment", name] => Ok(["shell", name])
			["task", name] => Ok(["run", name])
			["task", name, backend] => Ok(["run", backend, name])
			["build", name] => Ok(["build", name])
			["build", name, backend] => Ok(["build", backend, name])
			["machine", name] => Ok(["machine", name])
			["machine", name, backend] => Ok(["machine", backend, name])
			["workflow", name] => Ok(["workflow", name])
			["workflow", name, backend] => Ok(["workflow", backend, name])
			["update"] => Ok(["update"])
			["update", backend] => Ok(["update", backend])
			_ => Err(UnsupportedExampleHeader({ header, path }))
		}?
		Ok({ arch, args, os })
	}

	written_content = |actions, path|
		match actions {
			[] => ""
			[WriteUtf8({ content, path: written_path }), .. as rest] =>
				if written_path == path content else Examples.written_content(rest, path)
			[_, .. as rest] => Examples.written_content(rest, path)
		}

	check_invocations : Str, Str, List(Examples.Invocation) -> Try({}, _)
	check_invocations = |source, path, remaining_invocations|
		match remaining_invocations {
			[] => Ok({})
			[first, .. as rest] => {
				plan = Plugin.plan_registry(
					[StdPlugin.plugin],
					source,
					first.args,
					first.os,
					first.arch,
				) ? |problem|
					ExamplePlanningFailed({
						args: first.args,
						path,
						problem: Str.inspect(problem),
					})
				if plan.actions.is_empty() {
					Err(EmptyExamplePlan({ args: first.args, path }))
				} else {
					Examples.check_invocations(source, path, rest)
				}
			}
		}
}
