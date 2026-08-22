import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout

Kaifiles := [].{
	run! = || {
		workspace = Kaifiles.workspace!()?
		result = Kaifiles.run_in!(workspace)
		Path.delete_all!(workspace)?
		result
	}

	run_in! = |workspace| {
		root = Env.cwd!()?
		binary = Kaifiles.build_kai!(root, workspace)?
		directory = Path.join(root, "examples/kaifiles")
		kaifiles = Kaifiles.discover!(directory)?
		if kaifiles.is_empty() {
			Err(NoKaifilesFound(Path.display(directory)))
		} else {
			lock = Path.read_utf8!(Path.join(root, "kai.lock"))?
			host = Env.platform!()
			system = Kaifiles.system(host)?
			platform_name = Kaifiles.platform_name(host)?
			for fixture in kaifiles {
				Kaifiles.check!(binary, lock, platform_name, system, fixture)?
			}
			Stdout.line!("tested ${U64.to_str(kaifiles.len())} Kaifiles")?
			Ok({})
		}
	}

	build_kai! = |root, workspace| {
		binary = Path.join(workspace, "kai")
		source = Path.join(root, "xkai/stock-cli.roc")
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

	check! = |binary, lock, platform_name, system, fixture| {
		path = Path.display(fixture.kaifile)
		directory = fixture.directory
		args = Path.read_utf8!(Path.join(directory, "args"))?
			.split_on("\n")
			.map(Str.trim)
			.keep_if(|arg| !arg.is_empty())
		expected_root = Path.join(directory, "expected")
		platform_expected = Path.join(expected_root, platform_name)
		expected_directory = if Path.is_dir!(platform_expected)? platform_expected else expected_root
		expected_outputs = Path.list!(expected_directory)?
		if args.is_empty() {
			Err(EmptyKaifileArguments(path))
		} else if expected_outputs.is_empty() {
			Err(EmptyExpectedOutputs(path))
		} else {
			workspace = Kaifiles.workspace!()?
			result = Kaifiles.run_example!(binary, args, expected_outputs, fixture.kaifile, lock, path, system, workspace)
			Path.delete_all!(workspace)?
			_ = result?
			Stdout.line!("tested: ${path}")?
			Ok({})
		}
	}

	run_example! = |binary, args, expected_outputs, kaifile, lock, path, system, workspace| {
		Path.write_utf8!(Path.join(workspace, "Kaifile"), Path.read_utf8!(kaifile)?)?
		Path.write_utf8!(Path.join(workspace, "kai.lock"), lock)?

		original_directory = Env.cwd!()?
		Env.set_cwd!(workspace)?
		command_result = Cmd.new(Path.to_os_str(binary)).args_str(args).exec_output!()
		Env.set_cwd!(original_directory)?
		_ = command_result?

		for expected_path in expected_outputs {
			if !Path.is_file!(expected_path)? {
				return Err(ExpectedOutputFileRequired(Path.display(expected_path)))
			}
			name = Path.display(Path.filename(expected_path) ?? expected_path)
			if !name.ends_with(".expected") {
				return Err(ExpectedOutputSuffixRequired(name))
			}
			output_name = Str.from_utf8_lossy(name.to_utf8().drop_last(9))
			expected = Str.join_with(Path.read_utf8!(expected_path)?.split_on("{{system}}"), system)
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
