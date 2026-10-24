# Every environment variable kai reads, and what it is for.
import pf.Env
import pf.OsStr

Variables := [].{
	Variable : { name : Str, description : Str }

	roc = {
		name: "ROC",
		description: "The Roc compiler for Kaifile.roc (default: roc).",
	}

	kai_dir = {
		name: "KAI_DIR",
		description: "The project's workspace directory (default: .kai).",
	}

	no_color = {
		name: "NO_COLOR",
		description: "Print plain text without colors when non-empty.",
	}

	xdg_cache_home = {
		name: "XDG_CACHE_HOME",
		description: "The cache directory (default: ~/.cache).",
	}

	home = {
		name: "HOME",
		description: "The home directory, for ~/.cache.",
	}

	kai_platform_bundle = {
		name: "KAI_PLATFORM_BUNDLE",
		description: "An unpacked platform bundle to seed Roc's cache with.",
	}

	kai_std_bundle = {
		name: "KAI_STD_BUNDLE",
		description: "An unpacked std bundle to seed Roc's cache with.",
	}

	kai_roc_packages = {
		name: "KAI_ROC_PACKAGES",
		description: "Colon-separated Roc packages to seed Roc's cache with.",
	}

	out = {
		name: "out",
		description: "A Nix build's output path, for kai's build runner.",
	}

	all : List(Variable)
	all = [
		Variables.roc,
		Variables.kai_dir,
		Variables.no_color,
		Variables.xdg_cache_home,
		Variables.home,
		Variables.kai_platform_bundle,
		Variables.kai_std_bundle,
		Variables.kai_roc_packages,
		Variables.out,
	]

	read! : Variable => Try(Str, _)
	read! = |variable| Env.var_str!(OsStr.from_str(variable.name))
}
