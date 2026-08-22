# Pure release metadata parsing and artifact inventory.
Release := [].{
	PublicationInput : {
		branch_contains_target : Bool,
		branch_name : Str,
		canonical_version : Str,
		manifest_version : Str,
		name : Str,
		tag_name : Str,
		target_commit : Str,
	}
	MergedRelease : {
		assets : List(Str),
		name : Str,
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
				Release.is_number(major) and Release.is_number(minor) and Release.is_number(patch)
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
				([left_major, left_minor, left_patch], [right_major, right_minor, right_patch]) => {
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

	parse_github_origin : Str -> Try({ owner : Str, repository : Str }, [UnsupportedOrigin])
	parse_github_origin = |origin| {
		https_prefix = "https://github.com/"
		ssh_prefix = "ssh://git@github.com/"
		scp_prefix = "git@github.com:"
		if origin.starts_with(https_prefix) {
			Release.parse_repo_path(Str.join_with(origin.split_on(https_prefix).drop_first(1), https_prefix))
		} else if origin.starts_with(ssh_prefix) {
			Release.parse_repo_path(Str.join_with(origin.split_on(ssh_prefix).drop_first(1), ssh_prefix))
		} else if origin.starts_with(scp_prefix) {
			Release.parse_repo_path(Str.join_with(origin.split_on(scp_prefix).drop_first(1), scp_prefix))
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
			Release.ascii_lower(left_repo.owner) == Release.ascii_lower(right_repo.owner) and
				Release.ascii_lower(left_repo.repository) == Release.ascii_lower(right_repo.repository),
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
			Ok("https://github.com/${repository.owner}/${repository.repository}/compare/master...release%2Fv${version}?expand=1")
		}
	}

	is_commit_id = |commit| {
		bytes = Str.to_utf8(commit)
		(bytes.len() == 40 or bytes.len() == 64) and List.all(
			bytes,
			|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f') or (byte >= 'A' and byte <= 'F'),
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
			Err(PublicationManifestMismatch({ canonical: input.canonical_version, manifest: input.manifest_version }))
		} else if input.branch_name != "master" {
			Err(UnexpectedPublicationBranch(input.branch_name))
		} else if !input.branch_contains_target {
			Err(PublicationTargetNotOnMaster)
		} else if !Release.is_commit_id(input.target_commit) {
			Err(InvalidPublicationTarget(input.target_commit))
		} else if input.tag_name != expected_tag {
			Err(PublicationTagMismatch({ actual: input.tag_name, expected: expected_tag }))
		} else {
			Ok({
				assets: Release.inventory(input.canonical_version),
				name: input.name,
				tag_name: input.tag_name,
				target_commit: input.target_commit,
				version: input.canonical_version,
			})
		}
	}

	release_files = ["build.zig.zon", "xkai-bin/RELEASE_NAME", "xkai-bin/VERSION"]

	are_allowed_release_files : List(Str) -> Bool
	are_allowed_release_files = |files| {
		expected_length = if files.contains("xkai-bin/RELEASE_NAME") {
			3
		} else {
			2
		}
		files.contains("build.zig.zon") and
			files.contains("xkai-bin/VERSION") and
				files.len() == expected_length and
					List.all(files, |file| Release.release_files.contains(file))
	}

	manifest_version : Str -> Try(Str, [DuplicateManifestVersion, InvalidManifestVersion, MissingManifestVersion])
	manifest_version = |manifest|
		match manifest.split_on("\n").keep_if(|line| line.trim().starts_with(".version =")) {
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
			[before, version, after] if before.trim() == ".version =" and after.trim() == "," => Ok(version)
			_ => Err(InvalidVersionLine)
		}

	rewrite_manifest : Str, Str -> Try(Str, [DuplicateManifestVersion, InvalidManifestVersion, InvalidVersion, MissingManifestVersion])
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

	archive_names : Str -> { arm64 : Str, x64 : Str }
	archive_names = |version| {
		x64: "kai-${version}-x86_64-linux.tar.gz",
		arm64: "kai-${version}-aarch64-linux.tar.gz",
	}

	archive_inventory : Str -> List(Str)
	archive_inventory = |version| {
		names = Release.archive_names(version)
		[names.x64, names.arm64]
	}

	inventory : Str -> List(Str)
	inventory = |version| {
		names = Release.archive_names(version)
		["SHA256SUMS", names.arm64, names.x64]
	}

	is_exact_inventory : List(Str), List(Str) -> Bool
	is_exact_inventory = |actual, expected|
		actual.len() == expected.len() and List.all(expected, |name| actual.contains(name))

	is_release_workspace : Str -> Bool
	is_release_workspace = |name| name.starts_with(".release-build.")
}

## -- TESTS --

valid_versions = ["0.0.0", "0.0.2", "1.20.300", "18446744073709551616.2.3"]

invalid_versions = ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "1.-2.3", "1.2.x", "1.2.3-alpha", " 1.2.3", "1.2.3\n"]

expect List.all(valid_versions, Release.is_semver)
expect List.all(invalid_versions, |version| !Release.is_semver(version))

version_order_cases = [
	{ left: "0.0.2", right: "0.0.3", expected: LT },
	{ left: "1.10.0", right: "1.9.999", expected: GT },
	{ left: "18446744073709551616.2.3", right: "18446744073709551615.999.999", expected: GT },
	{ left: "999999999999999999999999.0.0", right: "999999999999999999999999.0.0", expected: EQ },
]
expect List.all(version_order_cases, |case| Release.version_order(case.left, case.right) == Ok(case.expected))
expect Release.version_order("1.0", "2.0.0") == Err(InvalidVersion)

name_cases = [
	{ name: "Kai 0.0.3", valid: Bool.True },
	{ name: " μοριων ", valid: Bool.True },
	{ name: "", valid: Bool.False },
	{ name: " \t ", valid: Bool.False },
	{ name: "line one\nline two", valid: Bool.False },
	{ name: "line one\rline two", valid: Bool.False },
	{ name: "line one line two", valid: Bool.False },
	{ name: "line one line two", valid: Bool.False },
]
expect List.all(name_cases, |case| Release.is_release_name(case.name) == case.valid)

origin_cases = [
	{ origin: "git@github.com:example-owner/example-repo.git", expected: Ok({ owner: "example-owner", repository: "example-repo" }) },
	{ origin: "ssh://git@github.com/example-owner/example-repo", expected: Ok({ owner: "example-owner", repository: "example-repo" }) },
	{ origin: "https://github.com/example-owner/example-repo.git", expected: Ok({ owner: "example-owner", repository: "example-repo" }) },
]
expect List.all(origin_cases, |case| Release.parse_github_origin(case.origin) == case.expected)

invalid_origins = ["git@gitlab.com:example-owner/example-repo.git", "https://github.com/example-owner/example-repo/extra", "/tmp/example-repo.git"]
expect List.all(
	invalid_origins,
	|origin|
		match Release.parse_github_origin(origin) {
			Err(UnsupportedOrigin) => Bool.True
			_ => Bool.False
		},
)

repository_cases = [
	{ left: "git@github.com:example-owner/example-repo.git", right: "https://github.com/example-owner/example-repo", expected: Ok(Bool.True) },
	{ left: "ssh://git@github.com/Example-Owner/Example-Repo.git", right: "git@github.com:example-owner/example-repo", expected: Ok(Bool.True) },
	{ left: "git@github.com:example-owner/example-repo.git", right: "git@github.com:redirected/example-repo.git", expected: Ok(Bool.False) },
	{ left: "git@github.com:example-owner/example-repo.git", right: "git@gitlab.com:example-owner/example-repo.git", expected: Err(UnsupportedOrigin) },
]
expect List.all(repository_cases, |case| Release.same_github_repository(case.left, case.right) == case.expected)
expect Release.pull_request_url("git@github.com:example-owner/example-repo.git", "1.2.3") == Ok("https://github.com/example-owner/example-repo/compare/master...release%2Fv1.2.3?expand=1")

allowed_file_cases = [
	{ files: ["build.zig.zon", "xkai-bin/VERSION"], allowed: Bool.True },
	{ files: ["xkai-bin/RELEASE_NAME", "xkai-bin/VERSION", "build.zig.zon"], allowed: Bool.True },
	{ files: ["xkai-bin/RELEASE_NAME"], allowed: Bool.False },
	{ files: ["build.zig.zon", "xkai-bin/VERSION", "xkai-bin/VERSION"], allowed: Bool.False },
	{ files: ["README.md", "build.zig.zon", "xkai-bin/VERSION"], allowed: Bool.False },
]
expect List.all(allowed_file_cases, |case| Release.are_allowed_release_files(case.files) == case.allowed)

manifest = ".{\n    .name = .kai,\n    .version = \"0.0.2\",\n    .paths = .{},\n}\n"

rewritten_manifest = ".{\n    .name = .kai,\n    .version = \"1.2.3\",\n    .paths = .{},\n}\n"

expect Release.manifest_version(manifest) == Ok("0.0.2")
expect Release.manifest_version(".version_suffix = \"ignored\",\n.version = \"0.0.2\",") == Ok("0.0.2")
expect Release.manifest_version(".version_suffix = \"ignored\",") == Err(MissingManifestVersion)
expect Release.manifest_version(".{ .name = .kai }") == Err(MissingManifestVersion)
expect Release.manifest_version(".version = 0.0.2,") == Err(InvalidManifestVersion)
expect Release.manifest_version(".version = \"0.0.2\",\n.version = \"1.0.0\",") == Err(DuplicateManifestVersion)
expect Release.rewrite_manifest(manifest, "1.2.3") == Ok(rewritten_manifest)
expect Release.rewrite_manifest(manifest, "01.2.3") == Err(InvalidVersion)

expect Release.archive_names("1.2.3") == {
	x64: "kai-1.2.3-x86_64-linux.tar.gz",
	arm64: "kai-1.2.3-aarch64-linux.tar.gz",
}
expect Release.archive_inventory("1.2.3") == [
	"kai-1.2.3-x86_64-linux.tar.gz",
	"kai-1.2.3-aarch64-linux.tar.gz",
]
expect Release.inventory("1.2.3") == [
	"SHA256SUMS",
	"kai-1.2.3-aarch64-linux.tar.gz",
	"kai-1.2.3-x86_64-linux.tar.gz",
]
expect Release.is_exact_inventory(["b", "a"], ["a", "b"])
expect !Release.is_exact_inventory(["a", "a"], ["a", "b"])
expect !Release.is_exact_inventory(["a", "b", "extra"], ["a", "b"])

publication_input = {
	branch_contains_target: Bool.True,
	branch_name: "master",
	canonical_version: "0.0.3",
	manifest_version: "0.0.3",
	name: "μοριων \"blue\" \\ path 🚀",
	tag_name: "v0.0.3",
	target_commit: "0123456789abcdef0123456789abcdef01234567",
}

merged_release = {
	assets: ["SHA256SUMS", "kai-0.0.3-aarch64-linux.tar.gz", "kai-0.0.3-x86_64-linux.tar.gz"],
	name: publication_input.name,
	tag_name: "v0.0.3",
	target_commit: publication_input.target_commit,
	version: "0.0.3",
}
expect Release.validate_publication(publication_input) == Ok(merged_release)
expect Release.validate_publication({ ..publication_input, name: " \t " }) == Err(InvalidPublicationName)
expect Release.validate_publication({ ..publication_input, canonical_version: "0.3" }) == Err(InvalidPublicationVersion("0.3"))
expect Release.validate_publication({ ..publication_input, manifest_version: "0.0.2" }) == Err(PublicationManifestMismatch({ canonical: "0.0.3", manifest: "0.0.2" }))
expect Release.validate_publication({ ..publication_input, branch_name: "release/v0.0.3" }) == Err(UnexpectedPublicationBranch("release/v0.0.3"))
expect Release.validate_publication({ ..publication_input, branch_contains_target: Bool.False }) == Err(PublicationTargetNotOnMaster)
expect Release.validate_publication({ ..publication_input, target_commit: "not-a-commit" }) == Err(InvalidPublicationTarget("not-a-commit"))
expect Release.validate_publication({ ..publication_input, tag_name: "v0.0.2" }) == Err(PublicationTagMismatch({ actual: "v0.0.2", expected: "v0.0.3" }))

# A workspace left by a failed build is removed when the next build starts.
expect Release.is_release_workspace(".release-build.failed")
expect !Release.is_release_workspace("release-build.failed")
expect !Release.is_release_workspace(".release-build")
