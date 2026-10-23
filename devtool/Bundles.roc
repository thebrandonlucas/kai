# The platform and std bundles Kai releases, as Kaifile.roc builds them: each
# is <hash>.tar.zst beside its unpacked <hash>/.
import pf.Path

import Exec

Bundles := [].{
	# Build a Kaifile.roc artifact and return its store path, which
	# `kai build` prints last on stdout.
	output! = |name| {
		output = Exec.output!(Exec.cmd("kai").args(Exec.strs(["build", name])))?
		lines = output.stdout_utf8.split_on("\n").keep_if(|line| !line.is_empty())
		match lines.last() {
			Ok(path) => Ok(Path.utf8(path))
			Err(_) => Err(UnexpectedKaiOutput({ name, output: output.stdout_utf8 }))
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

	bundle! = |name|
		Bundles.found!(Bundles.output!(name)?, name)

	# The platform bundle.
	platform! = || Bundles.bundle!("kai-platform")

}
