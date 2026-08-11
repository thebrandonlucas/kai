# Pure release metadata parsing and artifact inventory.
Release := [].{
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
			old_version = Release.manifest_version(manifest)?
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

# A workspace left by a failed build is removed when the next build starts.
expect Release.is_release_workspace(".release-build.failed")
expect !Release.is_release_workspace("release-build.failed")
expect !Release.is_release_workspace(".release-build")
