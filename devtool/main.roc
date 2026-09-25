# kai repo devtool entry point
app [main!] {
	pf: platform "../.basic-cli/main.roc",
	nix: "../kaifile/nix/main.roc",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout

import Cli
import ConfigFixtures
import GitHub
import KaiBuild
import KaiBundle
import KaiEnv
import KaiGuix
import KaiHelp
import KaiRun
import KaiUpdate
import KaiWorkflow
import PrepareRelease
import Release
import Tidy

validate_metadata! = || {
	version = Path.read_utf8!(Path.utf8("VERSION"))?
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
	output = Cmd.new(Path.to_os_str(binary)).arg_str("--version").exec_output!()?
	expected = "${version}\n"
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

# A release publishes the platform bundle its recorded URL names, so the URL
# cannot go stale.
check_platform_url! = |version, bundle| {
	origin = Cmd.new_str("git")
		.args_str(["config", "--get", "remote.origin.url"])
		.exec_output!()?
		.stdout_utf8
		.trim()
	repository = match Release.parse_github_origin(origin) {
		Ok(repo) => "${repo.owner}/${repo.repository}"
		Err(_) => return Err(UnsupportedReleaseOrigin(origin))
	}
	expected = Release.platform_url(repository, version, bundle.hash)
	recorded = Path.read_utf8!(Path.utf8(Release.platform_file))?.trim()
	if recorded == expected {
		Ok({})
	} else {
		Err(StalePlatformUrl({ expected, recorded }))
	}
}

build_release_stage! = |root, dist, workspace, version| {
	Stdout.line!("Building the Kaifile platform bundle through Nix...")?
	bundle = KaiBundle.platform!()?
	check_platform_url!(version, bundle)?
	copy_file!(bundle.archive, Path.join(dist, "${bundle.hash}.tar.zst"))?

	systems = Release.release_systems(
		Path.read_utf8!(Path.utf8(Release.systems_file))?,
	)?
	for system in systems {
		archive = Path.join(dist, Release.archive_name(version, system))
		Stdout.line!("Building and checking the ${system} CLI archive...")?
		copy_file!(KaiBundle.nix_output!(".#release-${system}")?, archive)?
		destination = Path.join(workspace, "${system}-cli-test")
		if system == "x86_64-linux" {
			check_x64!(archive, destination, version)?
		} else {
			check_arm64!(archive, destination)?
		}
	}

	archive_inventory = directory_inventory!(dist)?
	expected_archives = Release.archive_inventory(version, systems, bundle.hash)
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
		expected = Release.inventory(version, systems, bundle.hash)
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
	match Cli.parse(args.map(OsStr.display)) {
		Ok(Cli.Command.Help) => Stdout.line!(Cli.usage)
		Ok(Cli.Command.BuildRelease) => build_release!()
		Ok(Cli.Command.ConfigFixtures) => ConfigFixtures.run!()
		Ok(Cli.Command.KaiBuild(kai)) => KaiBuild.run!(kai)
		Ok(Cli.Command.KaiBundle(kai)) => KaiBundle.run!(kai)
		Ok(Cli.Command.KaiEnv(kai)) => KaiEnv.run!(kai)
		Ok(Cli.Command.KaiGuix({ kai, required })) => KaiGuix.run!(kai, required)
		Ok(Cli.Command.KaiHelp(kai)) => KaiHelp.run!(kai)
		Ok(Cli.Command.KaiRun(kai)) => KaiRun.run!(kai)
		Ok(Cli.Command.KaiUpdate(kai)) => KaiUpdate.run!(kai)
		Ok(Cli.Command.KaiWorkflow(kai)) => KaiWorkflow.run!(kai)
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
	{ args: ["config-fixtures"], expected: Ok(Cli.Command.ConfigFixtures) },
	{ args: ["kai-update", "kai"], expected: Ok(Cli.Command.KaiUpdate("kai")) },
	{ args: ["kai-env", "kai"], expected: Ok(Cli.Command.KaiEnv("kai")) },
	{ args: ["kai-build", "kai"], expected: Ok(Cli.Command.KaiBuild("kai")) },
	{ args: ["kai-bundle", "kai"], expected: Ok(Cli.Command.KaiBundle("kai")) },
	{
		args: ["kai-guix", "--require", "kai"],
		expected: Ok(Cli.Command.KaiGuix({ kai: "kai", required: Bool.True })),
	},
	{ args: ["kai-help", "kai"], expected: Ok(Cli.Command.KaiHelp("kai")) },
	{ args: ["kai-run", "kai"], expected: Ok(Cli.Command.KaiRun("kai")) },
	{
		args: ["kai-workflow", "kai"],
		expected: Ok(Cli.Command.KaiWorkflow("kai")),
	},
	{
		args: ["kai-update"],
		expected: Err(Cli.Error.ExpectedKaiBinary("kai-update")),
	},
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
		args: ["prepare-release", "only-name"],
		expected: Err(Cli.Error.ExpectedArguments("prepare-release")),
	},
	{ args: ["unknown"], expected: Err(Cli.Error.UnknownCommand("unknown")) },
]

usage_lines = [
	"Usage: kai-devtool <command> [arguments]",
	"build-release",
	"config-fixtures",
	"kai-build KAI_BINARY",
	"kai-bundle KAI_BINARY",
	"kai-env KAI_BINARY",
	"kai-guix [--require] KAI_BINARY",
	"kai-help KAI_BINARY",
	"kai-run KAI_BINARY",
	"kai-workflow KAI_BINARY",
	"kai-update KAI_BINARY",
	"prepare-release NAME VERSION",
	"tidy ROC_FILE...",
	"help",
]
