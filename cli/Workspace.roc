# Kai's project workspace: where the lock authority and generated backend
# files live, and the symlink-safe effects that are allowed to write there.
import pf.Env
import pf.OsStr
import pf.Path

import api.Layout
import ir.Plan

Workspace := [].{
	default_dir = ".kai"

	marker = ".kai-workspace"
	marker_contents = "Kai project workspace\n"

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
			dir.to_utf8().map(|b| if b >= 'A' and b <= 'Z' b + 32 else b),
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
				,
			)
		} else if lower == Workspace.default_dir and dir != Workspace.default_dir {
			Err("use the canonical '.kai' spelling for KAI_DIR")
		} else if Workspace.reserved.contains(lower) {
			Err("KAI_DIR ${dir} is reserved")
		} else {
			Ok({})
		}
	}

	# The whole authority and generated state move together with KAI_DIR.
	locate : Str, Str -> Layout
	locate = |root, dir| {
		workspace = Workspace.normalize("${root}/${dir}")
		Layout.{
			project_root: root,
			workspace,
			generated_root: "${workspace}/generated/nix",
			lock_path: "${workspace}/lock.json",
		}
	}

	locate! : Str => Try(Layout, _)
	locate! = |root| {
		dir = match Env.var_str!("KAI_DIR") {
			Ok(value) => value
			Err(VarNotFound(_)) => Workspace.default_dir
			Err(err) => return Err(err)
		}
		Workspace.validate_dir(dir).map_err(|message| InvalidWorkspace(message))?
		chosen = Workspace.locate(root, dir)
		Layout.validate(chosen).map_err(|message| InvalidWorkspace(message))?
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
		if result.is_empty() "/" else result
	}

	# A default workspace is Kai's by name; a custom one must carry Kai's
	# marker so KAI_DIR cannot adopt an unrelated existing directory.
	prepare! : Layout => Try({}, _)
	prepare! = |layout| {
		root = layout.workspace
		Workspace.safe_path!(root)?
		marker_path = "${root}/${Workspace.marker}"
		default = root == "${layout.project_root}/${Workspace.default_dir}"
		match Workspace.path(root).type!() {
			Ok(IsDir) if default => Ok({})
			Ok(IsDir) => {
				Workspace.safe_path!(marker_path)?
				owned = Workspace.path(marker_path).is_file!()?
					and Workspace.path(marker_path).read_utf8!()?
						== Workspace.marker_contents
				if owned {
					Ok({})
				} else {
					Err(UnsafeWorkspace("${root} is not a Kai workspace"))
				}
			}
			Ok(_) => Err(UnsafeWorkspace("${root} must be a directory"))
			Err(PathErr(NotFound, _)) => {
				Workspace.path(root).create_dir!()?
				if default {
					Ok({})
				} else {
					Workspace.path(marker_path).write_utf8!(Workspace.marker_contents)
				}
			}
			Err(err) => Err(err)
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
		match Workspace.path(value).type!()? {
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

# The whole authority and generated state live under the chosen KAI_DIR.
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
				"${workspace}/generated/nix",
				"${workspace}/lock.json",
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
		("/project/.kai/generated/nix", Bool.False),
		("/project/flake.nix", Bool.False),
	].all(
		|(target, ok)|
			Workspace.stageable({ path: target, contents: "" }, layout) == ok,
	)
}
