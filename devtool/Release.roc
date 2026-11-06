# Pure release metadata parsing and artifact inventory.
Release := [].{
	PublicationInput : {
		branch_contains_target : Bool,
		branch_name : Str,
		canonical_version : Str,
		manifest_version : Str,
		name : Str,

		## The Roc bundles a release publishes, by asset name.
		bundles : List(Str),

		## The release notes: the changelog's section for the version, then how
		## to use the release.
		notes : Str,
		systems : List(Str),
		tag_name : Str,
		target_commit : Str,
	}
	MergedRelease : {
		assets : List(Str),
		name : Str,
		notes : Str,
		tag_name : Str,
		target_commit : Str,
		version : Str,
	}
	PublicationError : [
		InvalidPublicationName,
		InvalidPublicationTarget(Str),
		InvalidPublicationVersion(Str),
		PublicationManifestMismatch({ canonical : Str, manifest : Str }),
		PublicationTagMismatch({ actual : Str, expected : Str }),
		PublicationTargetNotOnMaster,
		UnexpectedPublicationBranch(Str),
	]

	is_semver : Str -> Bool
	is_semver = |version|
		match version.split_on(".") {
			[major, minor, patch] =>
				Release.is_number(major) and
					Release.is_number(minor) and
						Release.is_number(patch)
			_ => Bool.False
		}

	is_number : Str -> Bool
	is_number = |part|
		match Str.to_utf8(part) {
			[] => Bool.False
			['0'] => Bool.True
			[first, .. as rest] if first >= '1' and first <= '9' =>
				List.all(rest, |byte| byte >= '0' and byte <= '9')
			_ => Bool.False
		}

	bytes_order = |left, right|
		match (left, right) {
			([], []) => EQ
			([left_byte, .. as left_rest], [right_byte, .. as right_rest]) =>
				if left_byte < right_byte {
					LT
				} else if left_byte > right_byte {
					GT
				} else {
					Release.bytes_order(left_rest, right_rest)
				}
			_ => EQ
		}

	component_order = |left, right| {
		left_bytes = Str.to_utf8(left)
		right_bytes = Str.to_utf8(right)
		if left_bytes.len() < right_bytes.len() {
			LT
		} else if left_bytes.len() > right_bytes.len() {
			GT
		} else {
			Release.bytes_order(left_bytes, right_bytes)
		}
	}

	version_order : Str, Str -> Try([EQ, GT, LT], [InvalidVersion])
	version_order = |left, right|
		if !Release.is_semver(left) or !Release.is_semver(right) {
			Err(InvalidVersion)
		} else {
			match (left.split_on("."), right.split_on(".")) {
				(
					[left_major, left_minor, left_patch],
					[right_major, right_minor, right_patch],
				) => {
					major = Release.component_order(left_major, right_major)
					minor = Release.component_order(left_minor, right_minor)
					Ok(
						if major != EQ {
							major
						} else if minor != EQ {
							minor
						} else {
							Release.component_order(left_patch, right_patch)
						},
					)
				}
				_ => Err(InvalidVersion)
			}
		}

	is_release_name : Str -> Bool
	is_release_name = |name|
		!name.trim().is_empty() and
			!name.contains("\n") and
				!name.contains("\r") and
					!name.contains(" ") and !name.contains(" ")

	is_github_part = |part|
		!part.is_empty() and List.all(
			Str.to_utf8(part),
			|byte|
				(byte >= 'a' and byte <= 'z') or
					(byte >= 'A' and byte <= 'Z') or
						(byte >= '0' and byte <= '9') or
							byte == '-' or byte == '_' or byte == '.',
		)

	parse_repo_path = |path| {
		parts = path.split_on("/")
		match parts {
			[owner, raw_repository] => {
				repository = if raw_repository.ends_with(".git") {
					Str.from_utf8_lossy(Str.to_utf8(raw_repository).drop_last(4))
				} else {
					raw_repository
				}
				if Release.is_github_part(owner) and Release.is_github_part(repository) {
					Ok({ owner, repository })
				} else {
					Err(UnsupportedOrigin)
				}
			}
			_ => Err(UnsupportedOrigin)
		}
	}

	parse_github_origin :
		Str -> Try({ owner : Str, repository : Str }, [UnsupportedOrigin])
	parse_github_origin = |origin| {
		https_prefix = "https://github.com/"
		ssh_prefix = "ssh://git@github.com/"
		scp_prefix = "git@github.com:"
		if origin.starts_with(https_prefix) {
			Release.parse_repo_path(
				Str.join_with(
					origin.split_on(https_prefix).drop_first(1),
					https_prefix,
				),
			)
		} else if origin.starts_with(ssh_prefix) {
			Release.parse_repo_path(
				Str.join_with(
					origin.split_on(ssh_prefix).drop_first(1),
					ssh_prefix,
				),
			)
		} else if origin.starts_with(scp_prefix) {
			Release.parse_repo_path(
				Str.join_with(
					origin.split_on(scp_prefix).drop_first(1),
					scp_prefix,
				),
			)
		} else {
			Err(UnsupportedOrigin)
		}
	}

	ascii_lower = |input|
		Str.from_utf8_lossy(
			Str.to_utf8(input).map(
				|byte|
					if byte >= 'A' and byte <= 'Z' {
						byte + 32
					} else {
						byte
					},
			),
		)

	same_github_repository : Str, Str -> Try(Bool, [UnsupportedOrigin])
	same_github_repository = |left, right| {
		left_repo = Release.parse_github_origin(left)?
		right_repo = Release.parse_github_origin(right)?
		Ok(
			Release.ascii_lower(left_repo.owner) ==
				Release.ascii_lower(right_repo.owner) and
				Release.ascii_lower(left_repo.repository) ==
					Release.ascii_lower(right_repo.repository),
		)
	}

	pull_request_url : Str, Str -> Try(Str, [InvalidVersion, UnsupportedOrigin])
	pull_request_url = |origin, version| {
		if !Release.is_semver(version) {
			Err(InvalidVersion)
		} else {
			repository = match Release.parse_github_origin(origin) {
				Ok(found) => found
				Err(UnsupportedOrigin) => return Err(UnsupportedOrigin)
			}
			Ok(
				Str.join_with(
					[
						"https://github.com/${repository.owner}/",
						"${repository.repository}/compare/master...",
						"release%2Fv${version}?expand=1",
					],
					"",
				),
			)
		}
	}

	is_commit_id = |commit| {
		bytes = Str.to_utf8(commit)
		(bytes.len() == 40 or bytes.len() == 64) and List.all(
			bytes,
			|byte|
				(byte >= '0' and byte <= '9') or
					(byte >= 'a' and byte <= 'f') or
						(byte >= 'A' and byte <= 'F'),
		)
	}

	validate_publication : PublicationInput -> Try(MergedRelease, PublicationError)
	validate_publication = |input| {
		expected_tag = "v${input.canonical_version}"
		if !Release.is_release_name(input.name) {
			Err(InvalidPublicationName)
		} else if !Release.is_semver(input.canonical_version) {
			Err(InvalidPublicationVersion(input.canonical_version))
		} else if input.manifest_version != input.canonical_version {
			Err(
				PublicationManifestMismatch({
					canonical: input.canonical_version,
					manifest: input.manifest_version,
				}),
			)
		} else if input.branch_name != "master" {
			Err(UnexpectedPublicationBranch(input.branch_name))
		} else if !input.branch_contains_target {
			Err(PublicationTargetNotOnMaster)
		} else if !Release.is_commit_id(input.target_commit) {
			Err(InvalidPublicationTarget(input.target_commit))
		} else if input.tag_name != expected_tag {
			Err(
				PublicationTagMismatch({
					actual: input.tag_name,
					expected: expected_tag,
				}),
			)
		} else {
			Ok({
				assets: Release.inventory(
					input.canonical_version,
					input.systems,
					input.bundles,
				),
				name: input.name,
				notes: input.notes,
				tag_name: input.tag_name,
				target_commit: input.target_commit,
				version: input.canonical_version,
			})
		}
	}

	# The file recording the released platform bundle's URL.
	platform_file = "platform-release"

	# The file recording the released std bundle's URL.
	std_file = "plugins/std-release"

	# The plugins under plugins/ other than std that a release bundles, each
	# against the release's own platform and std bundles: Kaifile.roc's
	# kai-NAME build makes the bundle, and plugin_file(NAME) records its URL.
	# A release build refuses a plugins/ directory this list leaves out.
	plugins = ["guix", "nixos", "sbom"]

	# The file recording the URL a release publishes plugin `name`'s bundle at.
	plugin_file : Str -> Str
	plugin_file = |name| "plugins/${name}-release"

	# The files recording the URLs of the bundles a release publishes.
	url_files = [Release.platform_file, Release.std_file]
		.concat(Release.plugins.map(Release.plugin_file))

	# A copy of the release's SHA256SUMS, from which flake.nix packages the
	# release archives.
	checksums_file = "RELEASE_SHA256SUMS"

	# The changelog: a release moves its Unreleased entries under the new
	# version, whose section becomes the GitHub release notes.
	changelog_file = "CHANGELOG.md"

	# The changelog with the Unreleased entries moved under a heading for the
	# version, leaving Unreleased empty. A release refuses to ship none.
	release_changelog :
		Str, Str, Str -> Try(Str, [EmptyUnreleased, MissingUnreleased])
	release_changelog = |changelog, version, date|
		match changelog.split_on("\n## [Unreleased]\n") {
			[before, after] => {
				sections = after.split_on("\n## ")
				entries = (sections.first() ?? "").trim()
				has_entries = List.any(
					entries.split_on("\n"),
					|line| !line.trim().is_empty() and !line.starts_with("### "),
				)
				if !has_entries {
					return Err(EmptyUnreleased)
				}
				released = "${before}\n## [Unreleased]\n\n"
					.concat("## [${version}] - ${date}\n\n${entries}\n")
				Ok(Str.join_with([released].concat(sections.drop_first(1)), "\n## "))
			}
			_ => Err(MissingUnreleased)
		}

	# The entries under a version's heading, which its release publishes as
	# its notes.
	changelog_section : Str, Str -> Try(Str, [MissingChangelogSection(Str)])
	changelog_section = |changelog, version|
		match changelog.split_on("\n## [${version}] - ") {
			[_, after] => {
				section = after.split_on("\n## ").first() ?? ""
				entries = Str.join_with(section.split_on("\n").drop_first(1), "\n")
				if entries.trim().is_empty() {
					Err(MissingChangelogSection(version))
				} else {
					Ok(entries.trim())
				}
			}
			_ => Err(MissingChangelogSection(version))
		}

	release_files = ["build.zig.zon", Release.changelog_file]
		.concat(Release.url_files)
		.concat([Release.checksums_file, "RELEASE_NAME", "VERSION"])

	# A new version changes VERSION and its build.zig.zon mirror together; a
	# release of the committed, never released version changes only its name.
	# Either way the changelog, the bundle URLs and so the checksums change; a
	# plugin's first release adds its URL file.
	are_allowed_release_files : List(Str) -> Bool
	are_allowed_release_files = |files| {
		bumped = files.contains("VERSION") and files.contains("build.zig.zon")
		kept = !files.contains("VERSION") and !files.contains("build.zig.zon")
		renamed = files.contains("RELEASE_NAME")
		required = Release.url_files
			.append(Release.checksums_file)
			.append(Release.changelog_file)
		expected_length =
			required.len() + (if (bumped) 2 else 0) + (if (renamed) 1 else 0)
		(bumped or (kept and renamed)) and
			List.all(required, |file| files.contains(file)) and
				files.len() == expected_length and
					List.all(files, |file| Release.release_files.contains(file))
	}

	manifest_version :
		Str ->
			Try(
				Str,
				[
					DuplicateManifestVersion,
					InvalidManifestVersion,
					MissingManifestVersion,
				],
			)
	manifest_version = |manifest|
		match manifest.split_on("\n").keep_if(
			|line| line.trim().starts_with(".version ="),
		) {
			[] => Err(MissingManifestVersion)
			[line] =>
				match Release.version_line(line) {
					Ok(version) => Ok(version)
					Err(_) => Err(InvalidManifestVersion)
				}
			_ => Err(DuplicateManifestVersion)
		}

	version_line : Str -> Try(Str, [InvalidVersionLine])
	version_line = |line|
		match line.trim().split_on("\"") {
			[before, version, after] =>
				if before.trim() == ".version =" and after.trim() == "," {
					Ok(version)
				} else {
					Err(InvalidVersionLine)
				}
			_ => Err(InvalidVersionLine)
		}

	rewrite_manifest :
		Str,
		Str ->
			Try(
				Str,
				[
					DuplicateManifestVersion,
					InvalidManifestVersion,
					InvalidVersion,
					MissingManifestVersion,
				],
			)
	rewrite_manifest = |manifest, version| {
		if !Release.is_semver(version) {
			Err(InvalidVersion)
		} else {
			old_version = match Release.manifest_version(manifest) {
				Ok(found) => found
				Err(DuplicateManifestVersion) => return Err(DuplicateManifestVersion)
				Err(InvalidManifestVersion) => return Err(InvalidManifestVersion)
				Err(MissingManifestVersion) => return Err(MissingManifestVersion)
			}
			lines = manifest.split_on("\n").map(
				|line|
					match Release.version_line(line) {
						Ok(found) if found == old_version => {
							parts = line.split_on("\"")
							match parts {
								[before, _, after] => "${before}\"${version}\"${after}"
								_ => line
							}
						}
						_ => line
					},
			)
			Ok(Str.join_with(lines, "\n"))
		}
	}

	# Lists, one per line, the systems a release publishes a CLI archive for.
	systems_file = "RELEASE_SYSTEMS"

	# The systems whose archive the x86_64 release host cannot run, each with
	# the variable through which release.yml reports the commit a native run
	# on that system verified. publish-release refuses to publish such an
	# archive unless its variable names the release commit.
	verified_envs = [
		("aarch64-linux", "KAI_AARCH64_VERIFIED_COMMIT"),
		("aarch64-darwin", "KAI_AARCH64_DARWIN_VERIFIED_COMMIT"),
	]

	# The systems a release publishes that no native run verified at commit
	# `target`, given each verified_envs variable's value.
	unverified_systems : List(Str), List((Str, Str)), Str -> List(Str)
	unverified_systems = |systems, values, target|
		Release.verified_envs.keep_oks(
			|(system, env)| {
				verified = values.keep_if(|(name, _)| name == env).first()
				match verified {
					Ok((_, commit)) if commit == target => Err(Verified)
					_ if !systems.contains(system) => Err(Unpublished)
					_ => Ok(system)
				}
			},
		)

	# Systems Kaifile.roc builds a release archive for.
	archive_systems = ["x86_64-linux", "aarch64-linux", "aarch64-darwin"]

	release_systems : Str -> Try(List(Str), [InvalidReleaseSystems(Str)])
	release_systems = |text| {
		systems = text.split_on("\n").map(Str.trim).keep_if(|line| !line.is_empty())
		valid = List.all(
			systems,
			|system|
				Release.archive_systems.contains(system)
					and systems.keep_if(|other| other == system).len() == 1,
		)
		if valid and !systems.is_empty() {
			Ok(systems)
		} else {
			Err(InvalidReleaseSystems(text))
		}
	}

	archive_name : Str, Str -> Str
	archive_name = |version, system| "kai-${version}-${system}.tar.gz"

	# Kaifile.roc headers reference a release's platform bundle by this URL;
	# Roc names the bundle by its content hash.
	platform_url : Str, Str, Str -> Str
	platform_url = |repository, version, hash|
		"https://github.com/${repository}/releases/download/"
			.concat("v${version}/${hash}.tar.zst")

	# Roc tells packages apart by URL minus version and hash, so a plugin
	# bundle's asset name, std's included, starts with the plugin's name.
	plugin_url : Str, Str, Str, Str -> Str
	plugin_url = |repository, version, name, hash|
		Release.platform_url(repository, version, "${name}-${hash}")

	std_url : Str, Str, Str -> Str
	std_url = |repository, version, hash|
		Release.plugin_url(repository, version, "std", hash)

	# The asset name in a recorded URL of plugin `name`'s bundle, for this
	# repository and version.
	plugin_asset : Str, Str, Str, Str -> Try(Str, [UnexpectedPluginUrl(Str)])
	plugin_asset = |url, repository, version, name| {
		asset = url.split_on("/").last() ?? ""
		hash = asset.drop_prefix("${name}-").drop_suffix(".tar.zst")
		expected = Release.plugin_url(repository, version, name, hash)
		if !hash.is_empty() and expected == url {
			Ok(asset)
		} else {
			Err(UnexpectedPluginUrl(url))
		}
	}

	# What a release's notes end with, after its section of the changelog:
	# the Kaifile.roc header naming its platform and std, and the line that
	# adds each plugin it bundles, as (name, URL).
	Notes : {
		repository : Str,
		pf : Str,
		std : Str,
		plugin_urls : List((Str, Str)),
	}

	notes : Notes -> Str
	notes = |{ repository, pf, std, plugin_urls }| {
		readme = "https://github.com/${repository}#guix"
		Str.join_with(
			[
				"## Using this release",
				"",
				"A `Kaifile.roc` on this release starts with:",
				"",
				"```roc",
				"app [kaifile] {",
				"\tpf: platform \"${pf}\",",
				"\tstd: \"${std}\",",
				"}",
				"```",
				"",
				"To use [Guix](${readme}), or another plugin released with it, add "
					.concat("the plugin's line to that header, and the plugin to ")
					.concat("`Kaifile.new` as the README describes:"),
				"",
				"```roc",
			]
				.concat(plugin_urls.map(|(name, url)| "\t${name}: \"${url}\","))
				.concat(["```", ""]),
			"\n",
		)
	}

	# The bundle hash in a recorded URL for this repository and version.
	platform_hash : Str, Str, Str -> Try(Str, [UnexpectedPlatformUrl(Str)])
	platform_hash = |url, repository, version| {
		hash = (url.split_on("/").last() ?? "").drop_suffix(".tar.zst")
		expected = Release.platform_url(repository, version, hash)
		if !hash.is_empty() and expected == url {
			Ok(hash)
		} else {
			Err(UnexpectedPlatformUrl(url))
		}
	}

	# The install script at the repository root, published with each release
	# so that releases/latest/download/install.sh installs the latest one.
	installer = "install.sh"

	# Everything SHA256SUMS covers: the CLI archives, the Roc bundles and the
	# install script.
	archive_inventory : Str, List(Str), List(Str) -> List(Str)
	archive_inventory = |version, systems, bundles|
		systems.map(|system| Release.archive_name(version, system))
			.concat(bundles)
			.append(Release.installer)

	inventory : Str, List(Str), List(Str) -> List(Str)
	inventory = |version, systems, bundles|
		["SHA256SUMS"].concat(Release.archive_inventory(version, systems, bundles))

	is_exact_inventory : List(Str), List(Str) -> Bool
	is_exact_inventory = |actual, expected|
		actual.len() == expected.len() and
			List.all(expected, |name| actual.contains(name))

	is_release_workspace : Str -> Bool
	is_release_workspace = |name| name.starts_with(".release-build.")
}

## -- TESTS --

valid_versions = ["0.0.0", "0.0.2", "1.20.300", "18446744073709551616.2.3"]

invalid_versions = [
	"",
	"1",
	"1.2",
	"1.2.3.4",
	"01.2.3",
	"1.02.3",
	"1.2.03",
	"1.-2.3",
	"1.2.x",
	"1.2.3-alpha",
	" 1.2.3",
	"1.2.3\n",
]

# A release changes the changelog and bundle URLs and either bumps the version
# or, for the committed, never released version, only renames it.
expect {
	urls = Release.url_files
		.append(Release.checksums_file)
		.append(Release.changelog_file)
	bump = ["VERSION", "build.zig.zon"]
	allowed = |files| Release.are_allowed_release_files(urls.concat(files))
	allowed(bump)
		and allowed(bump.concat(["RELEASE_NAME"]))
		and allowed(["RELEASE_NAME"])
		and !allowed([])
		and !allowed(["VERSION", "RELEASE_NAME"])
		and !allowed(["RELEASE_NAME", "README.md"])
		and !Release.are_allowed_release_files(Release.url_files.concat(bump))
		and !Release.are_allowed_release_files(
			urls.keep_if(|file| file != Release.plugin_file("guix")).concat(bump),
		)
}

# Each plugin's bundle is named after it, std's included.
expect {
	url = Release.plugin_url("o/r", "1.2.3", "guix", "h")
	url == "https://github.com/o/r/releases/download/v1.2.3/guix-h.tar.zst"
		and Release.std_url("o/r", "1.2.3", "h") == url.replace_each("guix-", "std-")
		and Release.plugin_asset(url, "o/r", "1.2.3", "guix") == Ok("guix-h.tar.zst")
		and Release.plugin_asset(url, "o/r", "1.2.4", "guix")
			== Err(UnexpectedPluginUrl(url))
		and Release.plugin_asset(url, "o/r", "1.2.3", "sbom")
			== Err(UnexpectedPluginUrl(url))
}

# The notes give the header and each plugin's line.
expect {
	notes = Release.notes({
		repository: "o/r",
		pf: "P",
		std: "S",
		plugin_urls: [("guix", "G"), ("sbom", "B")],
	})
	notes.contains("\tpf: platform \"P\",\n\tstd: \"S\",\n}")
		and notes.contains("```roc\n\tguix: \"G\",\n\tsbom: \"B\",\n```")
		and notes.contains("(https://github.com/o/r#guix)")
}

# Each archive the release host cannot run needs a native run of the release
# commit on its system.
expect {
	both = ["x86_64-linux", "aarch64-linux", "aarch64-darwin"]
	linux = ("KAI_AARCH64_VERIFIED_COMMIT", "c")
	darwin = ("KAI_AARCH64_DARWIN_VERIFIED_COMMIT", "c")
	Release.unverified_systems(both, [linux, darwin], "c") == []
		and Release.unverified_systems(both, [linux], "c") == ["aarch64-darwin"]
		and Release.unverified_systems(both, [darwin], "c") == ["aarch64-linux"]
		and Release.unverified_systems(both, [linux, darwin], "d")
			== ["aarch64-linux", "aarch64-darwin"]
		and Release.unverified_systems(["x86_64-linux"], [], "c") == []
		and Release.unverified_systems(["aarch64-darwin"], [linux], "c")
			== ["aarch64-darwin"]
}

# RELEASE_SYSTEMS lists each system Kaifile.roc builds an archive for at most
# once.
expect
	Release.release_systems("x86_64-linux\naarch64-linux\naarch64-darwin\n")
		== Ok(["x86_64-linux", "aarch64-linux", "aarch64-darwin"])
		and Release.release_systems("x86_64-linux\nx86_64-darwin\n").is_err()
		and Release.release_systems("aarch64-darwin\naarch64-darwin\n").is_err()

# A release publishes SHA256SUMS, and the archives, bundles and install script
# it covers.
expect
	Release.inventory("0.0.3", ["x86_64-linux"], ["h.tar.zst"])
		== ["SHA256SUMS", "kai-0.0.3-x86_64-linux.tar.gz", "h.tar.zst", "install.sh"]
