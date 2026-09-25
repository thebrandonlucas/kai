# Effectful Kaifile discovery, parsing, and operations for running them
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout

Kaifiles := [].{
	full_integration_command_kinds = ["image", "iso", "machine"]

	run! = || Kaifiles.run_suite!(Bool.False)

	run_smoke! = || Kaifiles.run_suite!(Bool.True)

	run_suite! = |smoke| {
		workspace = Kaifiles.workspace!()?
		result = Kaifiles.run_in!(workspace, smoke)
		Path.delete_all!(workspace)?
		result
	}

	run_in! = |workspace, smoke| {
		root = Env.cwd!()?
		binary = Kaifiles.build_kai!(root, workspace)?
		directory = Path.join(root, "examples/kaifiles")
		kaifiles = Kaifiles.discover!(directory)?
		if kaifiles.is_empty() {
			Err(NoKaifilesFound(Path.display(directory)))
		} else {
			lock = Path.read_utf8!(Path.join(root, "Kaifile.lock"))?
			host = Env.platform!()
			system = Kaifiles.system(host)?
			platform_name = Kaifiles.platform_name(host)?
			for fixture in kaifiles {
				Kaifiles.check!(
					binary,
					lock,
					platform_name,
					system,
					fixture,
					smoke,
				)?
			}
			Stdout.line!("processed ${U64.to_str(kaifiles.len())} Kaifiles")?
			Ok({})
		}
	}

	build_kai! = |root, workspace| {
		binary = Path.join(workspace, "kai")
		source = Path.join(root, "xkai/standard-cli.roc")
		output = "--output=${Path.display(binary)}"
		_ = Cmd.new_str("roc")
			.args([
				OsStr.utf8("build"),
				Path.to_os_str(source),
				OsStr.utf8("--opt=dev"),
				OsStr.utf8(output),
			])
			.exec_output!()?
		Ok(binary)
	}

	# Annotated to avoid a compiler hang:
	# https://github.com/roc-lang/roc/issues/11621
	# Remove this workaround once the Roc pin includes the fix.
	discover! : Path => Try(List(_), _)
	discover! = |path| {
		if Path.is_sym_link!(path)? or !Path.is_dir!(path)? {
			Ok([])
		} else {
			kaifile = Path.join(path, "Kaifile")
			if Path.is_file!(kaifile)? {
				Ok([{ directory: path, kaifile }])
			} else {
				Kaifiles.discover_entries!(Path.list!(path)?)
			}
		}
	}

	discover_entries! = |entries|
		match entries {
			[] => Ok([])
			[first, .. as rest] => {
				found = Kaifiles.discover!(first)?
				remaining = Kaifiles.discover_entries!(rest)?
				Ok(found.concat(remaining))
			}
		}

	check! = |binary, lock, platform_name, system, fixture, smoke| {
		path = Path.display(fixture.kaifile)
		directory = fixture.directory
		if !Kaifiles.supports_system!(directory, system)? {
			Stdout.line!("skipped on ${system}: ${path}")?
			return Ok({})
		}
		args = Path.read_utf8!(Path.join(directory, "args"))?
			.split_on("\n")
			.map(Str.trim)
			.keep_if(|arg| !arg.is_empty())
		if args.is_empty() {
			Err(EmptyKaifileArguments(path))
		} else if smoke and Kaifiles.is_full_integration(args) {
			Stdout.line!("skipped (full integration): ${path}")?
			Ok({})
		} else {
			expected_root = Path.join(directory, "expected")
			platform_expected = Path.join(expected_root, platform_name)
			expected_directory = if Path.is_dir!(platform_expected)? {
				platform_expected
			} else {
				expected_root
			}
			expected_outputs = Kaifiles.expected_outputs!(expected_directory)?
			if expected_outputs.is_empty() {
				Err(EmptyExpectedOutputs(path))
			} else {
				workspace = Kaifiles.workspace!()?
				result = Kaifiles.run_example!(
					binary,
					args,
					expected_outputs,
					fixture.kaifile,
					lock,
					path,
					system,
					workspace,
				)
				Path.delete_all!(workspace)?
				_ = result?
				Stdout.line!("tested: ${path}")?
				Ok({})
			}
		}
	}

	is_full_integration = |args|
		match args {
			[command_kind, ..] =>
				Kaifiles.full_integration_command_kinds.contains(command_kind)
			[] => Bool.False
		}

	supports_system! = |directory, system| {
		path = Path.join(directory, "systems")
		if Path.exists!(path)? {
			Ok(
				Path.read_utf8!(path)?
					.split_on("\n")
					.map(Str.trim)
					.contains(system),
			)
		} else {
			Ok(Bool.True)
		}
	}

	expected_outputs! = |root| Kaifiles.expected_entries!(Path.list!(root)?, "")

	expected_entries! = |entries, directory|
		match entries {
			[] => Ok([])
			[first, .. as rest] => {
				name = Path.display(Path.filename(first) ?? first)
				relative = if directory.is_empty() name else "${directory}/${name}"
				found = (
					if Path.is_sym_link!(first)? {
						Err(ExpectedOutputFileRequired(Path.display(first)))
					} else if Path.is_dir!(first)? {
						Kaifiles.expected_entries!(Path.list!(first)?, relative)
					} else if Path.is_file!(first)? {
						Ok([{ path: first, relative }])
					} else {
						Err(ExpectedOutputFileRequired(Path.display(first)))
					}
				)?
				remaining = Kaifiles.expected_entries!(rest, directory)?
				Ok(found.concat(remaining))
			}
		}

	run_example! = |
		binary,
		args,
		expected_outputs,
		kaifile,
		lock,
		path,
		system,
		workspace,
	| {
		Path.write_utf8!(Path.join(workspace, "Kaifile"), Path.read_utf8!(kaifile)?)?
		Path.write_utf8!(Path.join(workspace, "Kaifile.lock"), lock)?

		original_directory = Env.cwd!()?
		Env.set_cwd!(workspace)?
		command_result = Cmd.new(Path.to_os_str(binary))
			.args_str(args)
			.env_str("KAI_DIR", ".kai")
			.exec_output!()
		Env.set_cwd!(original_directory)?
		_ = command_result?

		for expected_output in expected_outputs {
			if !expected_output.relative.ends_with(".expected") {
				return Err(ExpectedOutputSuffixRequired(expected_output.relative))
			}
			output_name = Str.from_utf8_lossy(
				expected_output.relative.to_utf8().drop_last(9),
			)
			expected = Str.join_with(
				Path.read_utf8!(expected_output.path)?.split_on("{{system}}"),
				system,
			)
			actual_path = Path.join(Path.join(workspace, ".kai"), output_name)
			actual = Path.read_utf8!(actual_path)?
			if actual != expected {
				return Err(
					UnexpectedKaifileOutput({
						actual,
						expected,
						output: output_name,
						path,
					}),
				)
			}
		}
		Ok({})
	}

	workspace! = || {
		output = Cmd.new_str("mktemp")
			.args_str(["-d", "-t", "kai-kaifiles.XXXXXXXX"])
			.exec_output!()?
		Ok(Path.utf8(output.stdout_utf8.trim()))
	}

	platform_name = |host|
		match host.os {
			LINUX => Ok("linux")
			MACOS => Ok("macos")
			_ => Err(UnsupportedKaifilePlatform)
		}

	system = |host|
		match host {
			{ arch: X64, os: LINUX } => Ok("x86_64-linux")
			{ arch: AARCH64, os: LINUX } => Ok("aarch64-linux")
			{ arch: X64, os: MACOS } => Ok("x86_64-darwin")
			{ arch: AARCH64, os: MACOS } => Ok("aarch64-darwin")
			_ => Err(UnsupportedKaifilePlatform)
		}
}
