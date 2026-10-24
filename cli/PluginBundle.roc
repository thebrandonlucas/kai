# `kai bundle-plugin`: a plugin package bundled with `roc bundle` for this
# kai's release, as the Kaifile.roc's kai-std build bundles std, so a
# Kaifile.roc can name it by the URL it is hosted at.
import pf.Cmd
import pf.Env
import pf.OsStr

import "../platform-release" as platform_release : Str
import "../plugins/std-release" as std_release : Str

import Load

PluginBundle := [].{
	# Bundle the package in directory `plugin` into directory `output`, both
	# absolute, and return the bundle's path.
	create! : Str, Str => Try(Str, _)
	create! = |plugin, output| {
		temporary = Env.create_temp_dir_with_prefix!("kai-bundle-")?.to_str()?
		result = PluginBundle.staged!(plugin, output, "${temporary}/plugin")
		_ = Load.path(temporary).delete_all!()
		result
	}

	# Rewrite a copy's headers and bundle every file in it, main.roc first and
	# the rest sorted; earlier bundles in the directory are left out.
	staged! = |plugin, output, staging| {
		Load.path(plugin).copy_dir!(Load.path(staging))?
		listed = Cmd.new("find").args([".", "-type", "f"])
			.cwd(Load.path(staging))
			.capture!()?
		sorted = Cmd.new("sort")
			.env("LC_ALL", "C")
			.stdin(Bytes(listed.to_utf8()))
			.capture!()?
		files = sorted.split_on("\n").keep_if(
			|file| !file.is_empty() and !file.ends_with(".tar.zst"),
		)
		for file in files.keep_if(|file| file.ends_with("/main.roc")) {
			path = Load.path("${staging}/${file}")
			text = path.read_utf8!()?
			match PluginBundle.header(text) {
				Ok(rewritten) => path.write_utf8!(rewritten)?
				Err(NoPlatformReference) if file == "./main.roc" =>
					return Err(NoPlatformReference("${plugin}/main.roc"))
				Err(NoPlatformReference) => {}
			}
		}
		Load.path(output).create_all!()?
		others = files.keep_if(|file| file != "./main.roc")
		bundled = Cmd.new(OsStr.from_str(Load.compiler!()?))
			.args(["bundle", "main.roc"])
			.args(others.map(OsStr.from_str))
			.args(["--output-dir", OsStr.from_str(output)])
			.cwd(Load.path(staging))
			.run!()?
		printed = Str.from_utf8_lossy(bundled.stdout_bytes)
		if bundled.status != Exited(0) {
			return Err(
				BundleFailed(printed.concat(Str.from_utf8_lossy(bundled.stderr_bytes))),
			)
		}
		# roc reports `Created: <path>/<hash>.tar.zst`.
		created = printed.split_on("Created: ").get(1) ?? ""
		name = (created.split_on("\n").first() ?? "").split_on("/").last() ?? ""
		Ok("${output}/${name}")
	}

	# A package header, up to its first `}`, naming this kai's releases: a
	# `platform "…"` and an api.roc path (std's packages reach the platform's
	# modules through api.roc) become the platform release, and `std: "…"`
	# the std release. A header naming no platform is refused.
	header : Str -> Try(Str, [NoPlatformReference])
	header = |text| {
		(head, body) = match text.split_first("}") {
			Ok({ before, after }) => (before, "}${after}")
			Err(_) => (text, "")
		}
		release = platform_release.trim()
		var $pieces = []
		var $quoted = Bool.False
		var $found = Bool.False
		for piece in head.split_on("\"") {
			before = $pieces.last() ?? ""
			if !$quoted {
				$pieces = $pieces.append(piece)
			} else if before.ends_with("platform ") {
				$pieces = $pieces.append(release)
				$found = Bool.True
			} else if piece.ends_with("platform/api.roc") {
				$pieces = $pieces.drop_last(1).concat([before.concat("platform "), release])
				$found = Bool.True
			} else if before.ends_with("std: ") {
				$pieces = $pieces.append(std_release.trim())
			} else {
				$pieces = $pieces.append(piece)
			}
			$quoted = !$quoted
		}
		if $found {
			Ok(Str.join_with($pieces, "\"").concat(body))
		} else {
			Err(NoPlatformReference)
		}
	}
}

# The platform and std become this kai's releases; local packages stay.
expect {
	text =
		\\package [Deploy] {
		\\	pf: platform "../../../platform/main.roc",
		\\	std: "../../../plugins/std/main.roc",
		\\	local: "local/main.roc",
		\\}
		\\
		\\x = "std: "
		\\
	expected =
		\\package [Deploy] {
		\\	pf: platform "${platform_release.trim()}",
		\\	std: "${std_release.trim()}",
		\\	local: "local/main.roc",
		\\}
		\\
		\\x = "std: "
		\\
	PluginBundle.header(text) == Ok(expected)
}

# std's packages name the platform through api.roc.
expect
	PluginBundle.header("package [M] { api: \"../../platform/api.roc\" }\n")
		== Ok("package [M] { api: platform \"${platform_release.trim()}\" }\n")

# A header without a platform is refused.
expect PluginBundle.header("package [M] { model: \"m/main.roc\" }")
	== Err(NoPlatformReference)
