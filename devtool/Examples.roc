# Plan and check coverage of standard Kaifile examples
import pf.Path
import pf.Stdout

import parser.Blocks
import kai.Kaifile
import kai.Plugin
import std.StdPlugin

Examples := [].{
	Coverage := {
		block_names : List(Str),
		command_paths : List(List(Str)),
	}

	Inspection := {
		block_names : List(Str),
		hosts : List(Plugin.Host),
	}

	run! = |directories| {
		fixtures = Examples.discover_roots!(directories)?
		if fixtures.is_empty() {
			Err(NoKaifilesFound(directories))
		} else {
			coverage = Examples.check_fixtures!(fixtures)?
			Examples.ensure_coverage(coverage, StdPlugin.plugin.schema)?
			Stdout.line!("tested ${U64.to_str(fixtures.len())} Kaifile examples")?
			Ok({})
		}
	}

	discover_roots! = |directories|
		match directories {
			[] => Ok([])
			[first, .. as rest] => {
				root = Path.utf8(first)
				if !Path.is_dir!(root)? {
					Err(ExamplesDirectoryRequired(first))
				} else {
					found = Examples.discover!(root)?
					remaining = Examples.discover_roots!(rest)?
					Ok(found.concat(remaining))
				}
			}
		}

	discover! = |path| {
		if Path.is_sym_link!(path)? or !Path.is_dir!(path)? {
			Ok([])
		} else {
			kaifile = Path.join(path, "Kaifile")
			nested = Examples.discover_entries!(Path.list!(path)?)?
			if Path.is_file!(kaifile)? {
				Ok([{ directory: path, kaifile }].concat(nested))
			} else {
				Ok(nested)
			}
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

	check_fixtures! = |fixtures|
		match fixtures {
			[] => Ok(Examples.Coverage.{ block_names: [], command_paths: [] })
			[first, .. as rest] => {
				current = Examples.check_file!(first)?
				remaining = Examples.check_fixtures!(rest)?
				Ok(
					Examples.Coverage.{
						block_names: current.block_names.concat(remaining.block_names),
						command_paths: current.command_paths.concat(
							remaining.command_paths,
						),
					},
				)
			}
		}

	check_file! = |fixture| {
		path = Path.display(fixture.kaifile)
		source = Path.read_utf8!(fixture.kaifile)?
		args = Path.read_utf8!(Path.join(fixture.directory, "args"))?
			.split_on("\n")
			.map(Str.trim)
			.keep_if(|arg| !arg.is_empty())
		if args.is_empty() {
			return Err(EmptyKaifileArguments(path))
		}
		blocks = Blocks.scan(source) ? |diagnostic|
			InvalidExampleKaifile({ diagnostic: Str.inspect(diagnostic), path })
		inspection = Examples.inspect_blocks(blocks, path, Bool.True)?
		parsed = Plugin.parse_kaifile_blocks(
			source,
			StdPlugin.plugin.schema.blocks,
			"nix",
		) ? |diagnostic|
			InvalidExampleKaifile({ diagnostic: Str.inspect(diagnostic), path })
		if parsed.len() != inspection.block_names.len() {
			return Err(UnrecognizedExampleBlock(path))
		}
		hosts = if inspection.hosts.is_empty() {
			[Plugin.Host.{ arch: X64, os: LINUX }]
		} else {
			inspection.hosts
		}
		Examples.check_hosts(source, path, args, hosts)?
		validation_invocations = Examples.validation_invocations(blocks, path)?
		Examples.check_invocations(source, path, validation_invocations)?
		command_path = Examples.command_path(
			StdPlugin.plugin.schema.commands,
			args,
			[],
		)?
		Stdout.line!("tested: ${path}")?
		Ok(
			Examples.Coverage.{
				block_names: parsed.map(|block| block.kind),
				command_paths: [command_path],
			},
		)
	}

	inspect_blocks :
		List(Blocks.Block), Str, Bool -> Try(Examples.Inspection, _)
	inspect_blocks = |blocks, path, allow_hosts|
		match blocks {
			[] => Ok(Examples.Inspection.{ block_names: [], hosts: [] })
			[first, .. as rest] => {
				current = match first.header {
					["backend", _] if allow_hosts =>
						Ok(Examples.Inspection.{ block_names: [], hosts: [] })
					["on", "linux"] if allow_hosts =>
						Examples.inspect_host(first, path, LINUX, X64)
					["on", "macos"] if allow_hosts =>
						Examples.inspect_host(first, path, MACOS, AARCH64)
					["on", host] if allow_hosts =>
						Err(UnsupportedExampleHost({ host, path }))
					["on", ..] => Err(NestedExampleHost(path))
					[name, ..] => Ok(
						Examples.Inspection.{ block_names: [name], hosts: [] },
					)
					[] => Err(UnsupportedExampleHeader({ header: [], path }))
				}?
				remaining = Examples.inspect_blocks(rest, path, allow_hosts)?
				Ok(
					Examples.Inspection.{
						block_names: current.block_names.concat(
							remaining.block_names,
						),
						hosts: current.hosts.concat(remaining.hosts),
					},
				)
			}
		}

	inspect_host = |block, path, os, arch| {
		blocks = Blocks.scan(block.body) ? |diagnostic|
			InvalidExampleHostBlock({ diagnostic: Str.inspect(diagnostic), path })
		inspection = Examples.inspect_blocks(blocks, path, Bool.False)?
		Ok(
			Examples.Inspection.{
				block_names: inspection.block_names,
				hosts: [Plugin.Host.{ arch, os }],
			},
		)
	}

	validation_invocations = |blocks, path|
		Examples.collect_invocations(blocks, path, LINUX, X64, Bool.True)

	collect_invocations = |blocks, path, os, arch, allow_hosts|
		match blocks {
			[] => Ok([])
			[first, .. as rest] => {
				current_result = match first.header {
					["backend", _] if allow_hosts => Ok([])
					["secret", _] | ["secret", _, _] => Ok([])
					_ => if allow_hosts {
						match first.header {
							["on", "linux"] =>
								Examples.nested_invocations(first, path, LINUX, X64)
							["on", "macos"] =>
								Examples.nested_invocations(first, path, MACOS, AARCH64)
							["on", host] =>
								Err(UnsupportedExampleHost({ host, path }))
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
				}?
				remaining = Examples.collect_invocations(
					rest,
					path,
					os,
					arch,
					allow_hosts,
				)?
				Ok(current_result.concat(remaining))
			}
		}

	nested_invocations = |host_block, path, os, arch| {
		blocks = Blocks.scan(host_block.body) ? |diagnostic|
			InvalidExampleHostBlock({ diagnostic: Str.inspect(diagnostic), path })
		Examples.collect_invocations(blocks, path, os, arch, Bool.False)
	}

	invocation_for_header = |header, path, os, arch| {
		args = match header {
			["shell"] => Ok(["shell"])
			["shell", backend] => Ok(["shell", backend])
			["environment", name] => Ok(["shell", name])
			["environment", name, backend] => Ok(["shell", backend, name])
			["task", name] => Ok(["run", name])
			["task", name, backend] => Ok(["run", backend, name])
			["build", name] => Ok(["build", name])
			["build", name, backend] => Ok(["build", backend, name])
			["machine", name] => Ok(["machine", name])
			["machine", name, backend] => Ok(["machine", backend, name])
			["service", name] => Ok(["service", name])
			["service", name, backend] => Ok(["service", backend, name])
			["source", _] | ["source", _, _] => Ok(["update"])
			["workflow", name] => Ok(["workflow", name])
			["workflow", name, backend] => Ok(["workflow", backend, name])
			_ => Err(UnsupportedExampleHeader({ header, path }))
		}?
		Ok({ arch, args, os })
	}

	# Annotated to avoid a compiler hang:
	# https://github.com/roc-lang/roc/issues/11621
	# Remove this workaround once the Roc pin includes the fix.
	check_invocations : Str, Str, List(_) -> Try({}, _)
	check_invocations = |source, path, invocations|
		match invocations {
			[] => Ok({})
			[first, .. as rest] => {
				Examples.check_hosts(
					source,
					path,
					first.args,
					[
						{
							arch: first.arch,
							os: first.os,
						},
					],
				)?
				Examples.check_invocations(source, path, rest)
			}
		}

	check_hosts : Str, Str, List(Str), List(Plugin.Host) -> Try({}, _)
	check_hosts = |source, path, args, hosts|
		match hosts {
			[] => Ok({})
			[first, .. as rest] => {
				plan = Plugin.plan_registry(
					[StdPlugin.plugin],
					source,
					path,
					args,
					first.os,
					first.arch,
					Plugin.default_workspace_root,
				) ? |problem|
					ExamplePlanningFailed({
						args,
						path,
						problem: Str.inspect(problem),
					})
				if plan.steps.is_empty() {
					Err(EmptyExamplePlan({ args, path }))
				} else {
					Examples.check_hosts(source, path, args, rest)
				}
			}
		}

	command_path :
		List(Plugin.Command), List(Str), List(Str) -> Try(List(Str), _)
	command_path = |commands, args, prefix|
		match args {
			[] => Err(EmptyExampleCommand(prefix))
			[name, .. as rest] =>
				Examples.find_command_path(commands, name, rest, prefix)
			}

	find_command_path :
		List(Plugin.Command), Str, List(Str), List(Str) -> Try(List(Str), _)
	find_command_path = |commands, name, rest, prefix|
		match commands {
			[] => Err(UnknownExampleCommand(prefix.append(name)))
			[first, .. as remaining] => {
				syntax = Plugin.syntax_from_command(first)
				if syntax.name == name {
					path = prefix.append(name)
					match first {
						CommandGroup(group) =>
							Examples.command_path(group.commands, rest, path)
						CommandOnly(_) | CommandWithBlock(_) => Ok(path)
					}
				} else {
					Examples.find_command_path(remaining, name, rest, prefix)
				}
			}
		}

	leaf_command_paths :
		List(Plugin.Command), List(Str) -> List(List(Str))
	leaf_command_paths = |commands, prefix|
		match commands {
			[] => []
			[first, .. as rest] => {
				syntax = Plugin.syntax_from_command(first)
				path = prefix.append(syntax.name)
				current = match first {
					CommandGroup(group) =>
						Examples.leaf_command_paths(group.commands, path)
					CommandOnly(_) | CommandWithBlock(_) => [path]
				}
				current.concat(Examples.leaf_command_paths(rest, prefix))
			}
		}

	ensure_coverage : Examples.Coverage, Plugin.Schema -> Try({}, _)
	ensure_coverage = |coverage, schema| {
		missing_commands = Examples.leaf_command_paths(schema.commands, [])
			.keep_if(|path| !coverage.command_paths.contains(path))
		missing_blocks = schema.blocks
			.map(Kaifile.block_name)
			.keep_if(|name| !coverage.block_names.contains(name))
		if missing_commands.is_empty() and missing_blocks.is_empty() {
			Ok({})
		} else {
			Err(
				MissingExampleCoverage({
					blocks: missing_blocks,
					commands: missing_commands.map(
						|path| Str.join_with(path, " "),
					),
				}),
			)
		}
	}
}
