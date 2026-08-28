# kai repo devtool entry point
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/${
		""
	}F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout

import Cli
import Kaifiles
import GitHub
import PrepareRelease
import Release
import Tidy

validate_metadata! = || {
	version = Path.read_utf8!(Path.utf8("xkai/VERSION"))?
	if !Release.is_semver(version) {
		Err(InvalidReleaseVersion(version))
	} else {
		manifest = Path.read_utf8!(Path.utf8("build.zig.zon"))?
		manifest_version = match Release.manifest_version(manifest) {
			Ok(found) => found
			Err(error) => return Err(InvalidReleaseManifest(error))
		}
		if manifest_version == version {
			Ok(version)
		} else {
			Err(
				ManifestVersionMismatch({
					canonical: version,
					manifest: manifest_version,
				}),
			)
		}
	}
}

nix_output_path! = |attribute| {
	output = Cmd.new_str("nix")
		.args_str(["build", attribute, "--no-link", "--print-out-paths"])
		.exec_output!()?
	paths = output.stdout_utf8.split_on("\n").keep_if(|line| !line.is_empty())
	match paths {
		[path] => Ok(Path.utf8(path))
		_ => Err(UnexpectedNixOutput({ attribute, output: output.stdout_utf8 }))
	}
}

copy_file! = |source, destination|
	Cmd.exec!(
		OsStr.utf8("cp"),
		[OsStr.utf8("--"), Path.to_os_str(source), Path.to_os_str(destination)],
	)

require_release_host! = || {
	host = Env.platform!()
	match (host.os, host.arch) {
		(LINUX, X64) => Ok({})
		_ => Err(
			UnsupportedReleaseHost(
				"build-release requires an x86_64 Linux host",
			),
		)
	}
}

remove_stale_workspaces! = |root| {
	for entry in Path.list!(root)? {
		name = Path.display(Path.filename(entry) ?? entry)
		if Release.is_release_workspace(name) and !Path.is_sym_link!(entry)? {
			if Path.is_dir!(entry)? {
				Path.delete_all!(entry)?
			}
		}
	}
	Ok({})
}

archive_contents! = |archive| {
	output = Cmd.new_str("tar")
		.args([OsStr.utf8("-tzf"), Path.to_os_str(archive)])
		.exec_output!()?
	contents = output.stdout_utf8.split_on("\n").keep_if(|line| !line.is_empty())
	if contents == ["kai"] {
		Ok({})
	} else {
		Err(UnexpectedArchiveContents({ archive: Path.display(archive), contents }))
	}
}

extract_archive! = |archive, destination| {
	Path.create_dir!(destination)?
	Cmd.exec!(
		OsStr.utf8("tar"),
		[
			OsStr.utf8("-xzf"),
			Path.to_os_str(archive),
			OsStr.utf8("-C"),
			Path.to_os_str(destination),
			OsStr.utf8("--"),
			OsStr.utf8("kai"),
		],
	)?
	binary = Path.join(destination, "kai")
	if Path.is_file!(binary)? and Path.is_executable!(binary)? {
		Ok(binary)
	} else {
		Err(MissingExecutable(Path.display(binary)))
	}
}

check_x64! = |archive, destination, version| {
	archive_contents!(archive)?
	binary = extract_archive!(archive, destination)?
	output = Cmd.new(Path.to_os_str(binary)).arg_str("version").exec_output!()?
	expected = "kai version ${version}\n"
	if output.stdout_utf8 == expected {
		Ok({})
	} else {
		Err(UnexpectedVersionOutput({ actual: output.stdout_utf8, expected }))
	}
}

check_arm64! = |archive, destination| {
	archive_contents!(archive)?
	binary = extract_archive!(archive, destination)?
	output = Cmd.new_str("file").arg(Path.to_os_str(binary)).exec_output!()?
	if output.stdout_utf8.contains("ARM aarch64") {
		Ok({})
	} else {
		Err(WrongArchitecture(output.stdout_utf8))
	}
}

directory_inventory! = |directory| {
	entries = Path.list!(directory)?
	Ok(entries.map(|path| Path.display(Path.filename(path) ?? path)))
}

generate_checksums_here! = |dist, archive_names| {
	output = Cmd.new_str("sha256sum").args_str(archive_names).exec_output!()?
	Path.write_utf8!(Path.join(dist, "SHA256SUMS"), output.stdout_utf8)?
	Cmd.exec!(
		OsStr.utf8("sha256sum"),
		[OsStr.utf8("-c"), OsStr.utf8("SHA256SUMS")],
	)
}

generate_checksums! = |root, dist, archive_names| {
	Env.set_cwd!(dist)?
	result = generate_checksums_here!(dist, archive_names)
	restore = Env.set_cwd!(root)
	match result {
		Err(error) => Err(error)
		Ok({}) => restore
	}
}

build_release_stage! = |root, dist, workspace, version| {
	names = Release.archive_names(version)
	x64_archive = Path.join(dist, names.x64)
	arm64_archive = Path.join(dist, names.arm64)

	Stdout.line!("Building portable Linux CLI archives through Nix...")?
	x64_store = nix_output_path!(".#release-x86_64-linux")?
	arm64_store = nix_output_path!(".#release-aarch64-linux")?
	copy_file!(x64_store, x64_archive)?
	copy_file!(arm64_store, arm64_archive)?

	Stdout.line!("Checking packaged x86_64 Linux CLI...")?
	check_x64!(x64_archive, Path.join(workspace, "x64-cli-test"), version)?
	Stdout.line!("Checking packaged aarch64 Linux CLI...")?
	check_arm64!(arm64_archive, Path.join(workspace, "arm64-cli-test"))?

	archive_inventory = directory_inventory!(dist)?
	expected_archives = Release.archive_inventory(version)
	if !Release.is_exact_inventory(archive_inventory, expected_archives) {
		Err(
			UnexpectedArtifactInventory({
				actual: archive_inventory,
				expected: expected_archives,
			}),
		)
	} else {
		Stdout.line!("Generating checksums...")?
		generate_checksums!(root, dist, expected_archives)?
		inventory = directory_inventory!(dist)?
		expected = Release.inventory(version)
		if Release.is_exact_inventory(inventory, expected) {
			Ok(expected)
		} else {
			Err(UnexpectedArtifactInventory({ actual: inventory, expected }))
		}
	}
}

build_release! = || {
	version = validate_metadata!()?
	require_release_host!()?
	root = Env.cwd!()?
	remove_stale_workspaces!(root)?
	dist = Path.join(root, "dist")
	if Path.exists!(dist)? {
		Path.delete_all!(dist)?
	}
	Path.create_dir!(dist)?

	workspace_output = Cmd.new_str("mktemp")
		.args([
			OsStr.utf8("-d"),
			OsStr.utf8("-p"),
			Path.to_os_str(root),
			OsStr.utf8(".release-build.XXXXXX"),
		])
		.exec_output!()
	match workspace_output {
		Err(error) => {
			Path.delete_all!(dist) ?? {}
			Err(error)
		}
		Ok(output) => {
			workspace = Path.utf8(output.stdout_utf8.trim())
			match build_release_stage!(root, dist, workspace, version) {
				Err(error) => {
					Path.delete_all!(workspace) ?? {}
					Path.delete_all!(dist) ?? {}
					Err(error)
				}
				Ok(inventory) =>
					match Path.delete_all!(workspace) {
						Err(error) => {
							Path.delete_all!(dist) ?? {}
							Err(error)
						}
						Ok({}) => {
							Stdout.line!("")?
							Stdout.line!("Release artifacts:")?
							for artifact in inventory {
								Stdout.line!("  ${artifact}")?
							}
							Ok({})
						}
					}
				}
		}
	}
}

main! : List(OsStr) => Try({}, _)
main! = |args|
	match Cli.parse(args.drop_first(1).map(OsStr.display)) {
		Ok(Cli.Command.Help) => Stdout.line!(Cli.usage)
		Ok(Cli.Command.BuildRelease) => build_release!()
		Ok(Cli.Command.Kaifiles) => Kaifiles.run!()
		Ok(Cli.Command.PrepareRelease({ name, version })) => PrepareRelease.run!(
			name,
			version,
		)
		Ok(Cli.Command.Tidy(paths)) => Tidy.run!(paths)
		Err(error) => Err(InvalidArguments(Cli.error_message(error)))
	}

## -- TESTS --

parse_cases = [
	{ args: [], expected: Ok(Cli.Command.Help) },
	{ args: ["help"], expected: Ok(Cli.Command.Help) },
	{ args: ["build-release"], expected: Ok(Cli.Command.BuildRelease) },
	{ args: ["kaifiles"], expected: Ok(Cli.Command.Kaifiles) },
	{
		args: ["prepare-release", "μοριων", "0.0.3"],
		expected: Ok(
			Cli.Command.PrepareRelease({
				name: "μοριων",
				version: "0.0.3",
			}),
		),
	},
	{
		args: ["build-release", "extra"],
		expected: Err(Cli.Error.ArgumentsNotAllowed("build-release")),
	},
	{
		args: ["kaifiles", "extra"],
		expected: Err(Cli.Error.ArgumentsNotAllowed("kaifiles")),
	},
	{
		args: ["prepare-release", "only-name"],
		expected: Err(Cli.Error.ExpectedArguments("prepare-release")),
	},
	{ args: ["unknown"], expected: Err(Cli.Error.UnknownCommand("unknown")) },
]

usage_lines = [
	"Usage: kai-devtool <command> [arguments]",
	"build-release",
	"kaifiles",
	"prepare-release NAME VERSION",
	"tidy ROC_FILE...",
	"help",
]
