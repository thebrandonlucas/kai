# FetchLocked files of downloads many projects pin, for the systems they list.
import Config
import System

## FetchLocked files for each listed system, without writing out each URL:
##
## ```roc
## systems = ["x86_64-linux", "aarch64-darwin"]
## nightly = "nightly-2026-10-21-5349569"
##
## FetchLocked("roc", Downloads.roc_nightly(nightly, systems)),
## FetchLocked("t", Downloads.file("https://example.org/t-{system}", systems)),
## ```
Downloads :: [].{

	## A program that is one file at a URL naming the system: "{system}",
	## "{arch}" and "{os}" in the template stand for each system, such as
	## "aarch64-darwin", and its two parts, "aarch64" and "darwin".
	file : Str, List(System) -> List(Config.LockedFile)
	file = |template, systems|
		systems.map(
			|system| {
				name = system.to_str()
				(arch, os) = match name.split_first("-") {
					Ok({ before, after }) => (before, after)
					Err(_) => (name, "")
				}
				url = template
					.replace_each("{system}", name)
					.replace_each("{arch}", arch)
					.replace_each("{os}", os)
				{ system, url, mirrors: [], program: File }
			},
		)

	## The Roc compiler of a roc-lang/nightlies release, named by its tag such
	## as "nightly-2026-10-21-5349569": each listed system's archive, kept
	## whole as macOS's `roc` links with the `darwin` directory beside it. A
	## system the nightlies are not built for gets no file, for
	## FetchUnavailable to name.
	roc_nightly : Str, List(System) -> List(Config.LockedFile)
	roc_nightly = |tag, systems|
		systems.keep_oks(
			|system| {
				(build, extension) = match system.to_str() {
					"x86_64-linux" => ("linux_x86_64", "tar.gz")
					"aarch64-linux" => ("linux_arm64", "tar.gz")
					"aarch64-darwin" => ("macos_apple_silicon", "tar.gz")
					"x86_64-darwin" => ("macos_x86_64", "tar.gz")
					"x86_64-windows" => ("windows_x86_64", "zip")
					_ => return Err(NotBuilt)
				}
				program = if (extension == "zip") "roc.exe" else "roc"
				top = "roc_nightly-${build}-${tag.drop_prefix("nightly-")}"
				releases = "https://github.com/roc-lang/nightlies/releases/download"
				Ok({
					system,
					url: "${releases}/${tag}/${top}.${extension}",
					mirrors: [],
					program: Archive("${top}/${program}"),
				})
			},
		)
}

# Each system's archive and the compiler inside it, as the release names them.
expect {
	tag = "nightly-2026-10-21-5349569"
	systems = ["x86_64-linux", "aarch64-darwin", "x86_64-windows"]
	base = "https://github.com/roc-lang/nightlies/releases/download/${tag}"
	top = |build| "roc_nightly-${build}-2026-10-21-5349569"
	Downloads.roc_nightly(tag, systems).map(|f| (f.url, f.program))
		== [
			(
				"${base}/${top("linux_x86_64")}.tar.gz",
				Archive("${top("linux_x86_64")}/roc"),
			),
			(
				"${base}/${top("macos_apple_silicon")}.tar.gz",
				Archive("${top("macos_apple_silicon")}/roc"),
			),
			(
				"${base}/${top("windows_x86_64")}.zip",
				Archive("${top("windows_x86_64")}/roc.exe"),
			),
		]
}

# A system no nightly is built for gets no file.
expect Downloads.roc_nightly("nightly-2026-10-21-5349569", ["riscv64-linux"])
	.is_empty()

# A file's template takes the system, or its parts.
expect
	Downloads.file("https://example.org/{os}/{arch}/t-{system}", ["x86_64-linux"])
		.map(|f| f.url)
		== ["https://example.org/linux/x86_64/t-x86_64-linux"]
