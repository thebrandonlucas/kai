# Kai's project workspace: where the lock authority and generated backend
# files live, and the symlink-safe effects that are allowed to write there.
import pf.Env
import pf.OsStr
import pf.Path

import api.Layout
import api.Plan

import Variables

Workspace := [].{
	default_dir = ".kai"

	marker = ".kai-workspace"
	marker_contents = "Kai project workspace\n"

	# Git leaves what Kai generates untracked, apart from the lock.
	ignore = ".gitignore"
	ignore_contents =
		\\# Kai's workspace: commit lock.json; the rest is generated.
		\\*
		\\!/lock.json
		\\

	# A KAI_DIR holds only generated files: the lock stays in .kai.
	generated_ignore_contents =
		\\# Kai's generated files; the lock is .kai/lock.json.
		\\*
		\\

	# Names that would alias version control or configuration, lowercased.
	reserved = [
		".bzr",
		".git",
		".hg",
		".jj",
		".svn",
		"_darcs",
		"cvs",
		"kaifile",
		"kaifile.lock",
		"kaifile.roc",
	]

	# KAI_DIR is one top-level directory name beneath the project root.
	validate_dir : Str -> Try({}, Str)
	validate_dir = |dir| {
		lower = Str.from_utf8_lossy(
			dir.to_utf8().map(|b| if (b >= 'A' and b <= 'Z') b + 32 else b),
		)
		allowed = |b|
			(b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')
				or (b >= '0' and b <= '9') or b == '.' or b == '_' or b == '-'
		if dir.is_empty() {
			Err("KAI_DIR must not be empty")
		} else if dir == "." or dir == ".." {
			Err("KAI_DIR must not be '.' or '..'")
		} else if dir.starts_with("-") {
			Err("KAI_DIR must not start with '-'")
		} else if !dir.to_utf8().all(allowed) {
			Err(
				\\KAI_DIR must be one relative top-level directory name
				\\containing only ASCII letters, digits, '.', '_', and '-'
			)
		} else if lower == Workspace.default_dir and dir != Workspace.default_dir {
			Err("use the canonical '.kai' spelling for KAI_DIR")
		} else if Workspace.reserved.contains(lower) {
			Err("KAI_DIR ${dir} is reserved")
		} else {
			Ok({})
		}
	}

	# KAI_DIR moves generated files and caches; the lock, which a project
	# commits, stays in .kai whatever KAI_DIR is.
	locate : Str, Str -> Layout
	locate = |root, dir| {
		workspace = Workspace.normalize("${root}/${dir}")
		Layout.{
			project_root: root,
			workspace,
			generated_root: "${workspace}/generated",
			lock_path: Workspace.normalize(
				"${root}/${Workspace.default_dir}/lock.json",
			),
		}
	}

	locate! : Str => Try(Layout, _)
	locate! = |root| {
		dir = match Variables.read!(Variables.kai_dir) {
			Ok(value) => value
			Err(VarNotFound(_)) => Workspace.default_dir
			Err(err) => return Err(err)
		}
		Workspace.validate_dir(dir).map_err(|message| InvalidWorkspace(message))?
		chosen = Workspace.locate(root, dir)
		Layout.validate(chosen).map_err(|message| InvalidWorkspace(message))?
		# Kai once kept the lock in KAI_DIR; say where it goes now rather than
		# plan as if the project had none.
		earlier = "${chosen.workspace}/lock.json"
		if
			dir != Workspace.default_dir
				and (Workspace.path(earlier).is_file!() ?? Bool.False)
				and !(Workspace.path(chosen.lock_path).exists!() ?? Bool.False)
				{
					moved = "kai reads the lock from ${chosen.lock_path} "
						.concat("whatever KAI_DIR is; move ${earlier} there")
					return Err(InvalidWorkspace(moved))
				}
		Ok(chosen)
	}

	# Lexical normalization is separate from the runtime no-symlink check.
	normalize : Str -> Str
	normalize = |value| {
		parts = value.split_on("/").fold(
			[],
			|acc, part|
				match part {
					"" | "." => acc
					".." => acc.drop_last(1)
					_ => acc.append(part)
				},
		)
		"/${Str.join_with(parts, "/")}"
	}

	parent : Str -> Str
	parent = |value| {
		result = Str.join_with(value.split_on("/").drop_last(1), "/")
		if (result.is_empty()) "/" else result
	}

	# The default workspace is Kai's by name. Kai overwrites and deletes files
	# in a custom one, so KAI_DIR adopts only a new or empty directory, which
	# it marks, or one with Kai's marker, never an unrelated directory.
	prepare! : Layout => Try({}, _)
	prepare! = |layout| {
		root = layout.workspace
		if root == Workspace.parent(layout.lock_path) {
			return Workspace.prepare_lock!(layout)
		}
		Workspace.safe_path!(root)?
		marker_path = "${root}/${Workspace.marker}"
		match Workspace.path(root).type!() {
			Ok(IsDir) => {
				Workspace.safe_path!(marker_path)?
				owned = Workspace.path(marker_path).is_file!()?
					and Workspace.path(marker_path).read_utf8!()?
						== Workspace.marker_contents
				if !owned {
					if !Workspace.path(root).list!()?.is_empty() {
						return Err(UnsafeWorkspace(Workspace.refusal(root)))
					}
					Workspace.path(marker_path).write_utf8!(Workspace.marker_contents)?
				}
			}
			Ok(_) => return Err(UnsafeWorkspace("${root} must be a directory"))
			Err(PathErr(NotFound, _)) => {
				Workspace.path(root).create_dir!()?
				Workspace.path(marker_path).write_utf8!(Workspace.marker_contents)?
			}
			Err(err) => return Err(err)
		}
		Workspace.ignore!(root, Workspace.generated_ignore_contents)
	}

	# Why KAI_DIR may not name a directory Kai did not make, and what to do.
	refusal : Str -> Str
	refusal = |root|
		"${root} is not a Kai workspace: kai writes and deletes files in KAI_DIR, "
			.concat("so it uses only a new or empty directory, or one it made, ")
			.concat("which holds ${Workspace.marker}; set KAI_DIR to such a name")

	# The lock's directory, .kai, is Kai's by name; Kai makes it to publish
	# the lock when KAI_DIR moved everything else.
	prepare_lock! : Layout => Try({}, _)
	prepare_lock! = |layout| {
		root = Workspace.parent(layout.lock_path)
		Workspace.safe_path!(root)?
		match Workspace.path(root).type!() {
			Ok(IsDir) => {}
			Ok(_) => return Err(UnsafeWorkspace("${root} must be a directory"))
			Err(PathErr(NotFound, _)) => Workspace.path(root).create_dir!()?
			Err(err) => return Err(err)
		}
		Workspace.ignore!(root, Workspace.ignore_contents)
	}

	# A workspace without a .gitignore, such as a fresh clone's, gets Kai's;
	# one already there, such as the user's own, is left alone.
	ignore! : Str, Str => Try({}, _)
	ignore! = |root, contents| {
		ignore_path = "${root}/${Workspace.ignore}"
		match Workspace.path(ignore_path).type!() {
			Err(PathErr(NotFound, _)) => Workspace.atomic_write!(ignore_path, contents)
			_ => Ok({})
		}
	}

	# Refuse destination/source aliases before touching caller-owned files.
	safe_path! : Str => Try({}, _)
	safe_path! = |value| {
		if !value.starts_with("/") or Workspace.normalize(value) != value {
			return Err(UnsafePath(value))
		}
		if Workspace.path(value).is_sym_link!()? {
			return Err(UnsafePath(value))
		}
		if value != "/" {
			Workspace.safe_path!(Workspace.parent(value))?
		}
		Ok({})
	}

	# Local pins may not smuggle host files into Nix through symbolic links.
	safe_source! : Str => Try({}, _)
	safe_source! = |value| {
		Workspace.safe_path!(value)?
		kind = match Workspace.path(value).type!() {
			Err(PathErr(NotFound, _)) => return Err(MissingSource(value))
			other => other?
		}
		match kind {
			IsDir => {
				for child in Workspace.path(value).list!()? {
					Workspace.safe_source!(child.to_str()?)?
				}
				Ok({})
			}
			IsFile => Ok({})
			_ => Err(UnsafePath(value))
		}
	}

	# Generated files stay beneath the generated root, never on the authority.
	stageable : Plan.File, Layout -> Bool
	stageable = |file, layout|
		file.path.starts_with("${layout.generated_root}/")
			and file.path != layout.lock_path

	stage! : List(Plan.File), Layout => Try({}, _)
	stage! = |files, layout| {
		Workspace.safe_path!(layout.generated_root)?
		for file in files {
			if !Workspace.stageable(file, layout) {
				return Err(UnsafePath(file.path))
			}
			Workspace.safe_path!(file.path)?
		}
		for file in files {
			Workspace.path(Workspace.parent(file.path)).create_all!()?
			Workspace.atomic_write!(file.path, file.contents)?
		}
		Ok({})
	}

	# Rename publication avoids truncation and overwriting hard-linked contents.
	atomic_write! : Str, Str => Try({}, _)
	atomic_write! = |destination, contents|
		Workspace.publish!(destination, |staged| staged.write_utf8!(contents))

	# Builds run this executable (the binary, not a wrapper script) as their
	# sandboxed runner; see NixBackend.runner_command.
	install_runner! : Str => Try({}, _)
	install_runner! = |destination| {
		Workspace.safe_path!(destination)?
		executable = Env.exe_path!()?
		Workspace.publish!(destination, |staged| executable.copy!(staged))
	}

	publish! = |destination, write!| {
		temporary = Env.create_temp_dir_in!(
			Workspace.path(Workspace.parent(destination)),
			".kai-write-",
		)?
		staged = temporary.join("file")
		result = match write!(staged) {
			Ok({}) =>
				match Workspace.safe_path!(destination) {
					Ok({}) => staged.rename!(Workspace.path(destination))
					Err(err) => Err(err)
				}
			Err(err) => Err(err)
		}
		_ = temporary.delete_all!()
		result
	}

	path : Str -> Path
	path = |p| Path.from_os_str(OsStr.from_str(p))
}

# KAI_DIR accepts one safe top-level name and rejects aliases of project data.
expect [
	(".kai", Bool.True),
	("kai-state", Bool.True),
	("_build.v2", Bool.True),
	("", Bool.False),
	(".", Bool.False),
	("..", Bool.False),
	("-kai", Bool.False),
	("a/b", Bool.False),
	("/abs", Bool.False),
	("with space", Bool.False),
	("é", Bool.False),
	(".KAI", Bool.False),
	(".git", Bool.False),
	("CVS", Bool.False),
	("Kaifile.roc", Bool.False),
	("kaifile.lock", Bool.False),
].all(|(dir, ok)| Workspace.validate_dir(dir).is_ok() == ok)

# Generated state lives under the chosen KAI_DIR, and the lock, which a
# project commits, in .kai whatever KAI_DIR is.
expect [(".kai", "/project/.kai"), ("state", "/project/state")].all(
	|(dir, workspace)| {
		layout = Workspace.locate("/project", dir)
		[
			layout.project_root,
			layout.workspace,
			layout.generated_root,
			layout.lock_path,
		]
			== [
				"/project",
				workspace,
				"${workspace}/generated",
				"/project/.kai/lock.json",
			]
	},
)

# Equivalent lexical locations normalize before filesystem safety checks.
expect [
	("/project/a/.././.kai/", "/project/.kai"),
	("/../x//y", "/x/y"),
	("/", "/"),
].all(|(input, output)| Workspace.normalize(input) == output)

# The parent of a top-level entry is the filesystem root.
expect [("/project/.kai/lock.json", "/project/.kai"), ("/project", "/")]
	.all(|(input, output)| Workspace.parent(input) == output)

# A rendered file aimed at the authority or outside generated state is refused.
expect {
	layout = Workspace.locate("/project", ".kai")
	[
		("/project/.kai/generated/nix/flake.nix", Bool.True),
		("/project/.kai/lock.json", Bool.False),
		("/project/.kai/generated", Bool.False),
		("/project/flake.nix", Bool.False),
	].all(
		|(target, ok)|
			Workspace.stageable({ path: target, contents: "" }, layout) == ok,
	)
}

# Kai's .gitignore ignores the whole workspace but its lock, and ends with a
# newline as checks for text files expect.
expect {
	layout = Workspace.locate("/project", ".kai")
	lines = Workspace.ignore_contents.split_on("\n")
	lines.contains("*")
		and lines.contains("!${layout.lock_path.drop_prefix(layout.workspace)}")
		and Workspace.ignore_contents.ends_with("\n")
}

# A custom KAI_DIR's .gitignore ignores everything in it, for the lock is not
# there.
expect {
	lines = Workspace.generated_ignore_contents.split_on("\n")
	lines.contains("*")
		and !lines.any(|line| line.starts_with("!"))
		and Workspace.generated_ignore_contents.ends_with("\n")
}

# Refusing a directory says why and how to choose another.
expect {
	message = Workspace.refusal("/project/.zig-cache")
	[
		"/project/.zig-cache",
		"writes and deletes",
		"new or empty",
		Workspace.marker,
	].all(|part| message.contains(part))
}
