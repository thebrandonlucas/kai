# The platform and std bundles Kai releases, as the flake builds them: each
# is <hash>.tar.zst beside its unpacked <hash>/.
import pf.Cmd
import pf.Path

Bundles := [].{
	# Build a flake output and return its store path.
	nix_output! = |attribute| {
		output = Cmd.new_str("nix")
			.args_str(["build", attribute, "--no-link", "--print-out-paths"])
			.exec_output!()?
		match output.stdout_utf8.split_on("\n").keep_if(|line| !line.is_empty()) {
			[path] => Ok(Path.utf8(path))
			_ => Err(UnexpectedNixOutput({ attribute, output: output.stdout_utf8 }))
		}
	}

	names! = |dir|
		Ok(Path.list!(dir)?.map(|p| Path.display(Path.filename(p) ?? p)))

	# A bundle's <hash>.tar.zst, its hash and its unpacked <hash>/.
	found! = |dir, what| {
		names = Bundles.names!(dir)?
		match names.keep_if(|name| name.ends_with(".tar.zst")) {
			[name] => {
				hash = name.drop_suffix(".tar.zst")
				Ok({
					archive: Path.join(dir, name),
					hash,
					unpacked: Path.join(dir, hash),
				})
			}
			_ => Err(UnexpectedBundle({ what, names }))
		}
	}

	bundle! = |attribute|
		Bundles.found!(Bundles.nix_output!(attribute)?, attribute)

	# The platform bundle.
	platform! = || Bundles.bundle!(".#kai-platform")

}
