# Caller-owned paths. Planning validates them without observing the filesystem.
Layout := {
	project_root : Str,
	workspace : Str,
	generated_root : Str,
	lock_path : Str,
}.{
	validate : Layout -> Try({}, Str)
	validate = |layout| {
		for path in [
			layout.project_root,
			layout.workspace,
			layout.generated_root,
			layout.lock_path,
		] {
			if !path.starts_with("/") or path == "/"
				or path.to_utf8().any(|b| b < 32 or b == 127)
					or ["#", "?", "%", "\\"].any(|part| path.contains(part))
						or path.split_on("/").drop_first(1).any(
							|part| part.is_empty() or part == "." or part == "..",
						) {
				return Err("layout paths must be normalized absolute paths")
			}
		}
		for directory in [layout.workspace, layout.generated_root] {
			if contains(directory, layout.project_root) {
				return Err("generated/workspace root cannot contain the project")
			}
		}
		for directory in [
			layout.project_root,
			layout.workspace,
			layout.generated_root,
		] {
			if contains(layout.lock_path, directory) {
				return Err("lock path must not contain a layout directory")
			}
		}
		Ok({})
	}

	## Lexical containment; the executor additionally checks symlinks.
	contains : Str, Str -> Bool
	contains = |parent, child| child == parent or child.starts_with("${parent}/")
}

# Callers may choose separate roots and keep authority within their workspace.
expect Layout.validate(
	Layout.{
		project_root: "/project",
		workspace: "/work",
		generated_root: "/work/nix",
		lock_path: "/work/inputs.lock",
	},
).is_ok()

# Traversal, URI delimiters and an authority ancestor cannot become effects.
expect [
	"relative",
	"/",
	"/project/../escape",
	"/project//workspace",
	"/project/#fragment",
	"/project/?query",
	"/project/%20space",
]
	.all(
		|workspace| Layout.validate(
			Layout.{
				project_root: "/project",
				workspace,
				generated_root: "/generated",
				lock_path: "/authority/inputs.lock",
			},
		).is_err(),
	)
	and Layout.validate(
		Layout.{
			project_root: "/project",
			workspace: "/work",
			generated_root: "/generated",
			lock_path: "/work",
		},
	).is_err()
