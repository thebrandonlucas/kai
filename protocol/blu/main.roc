# blu: the reference Blueprint backend (see ../README.md).
app [main!] {
	pf: platform "../../.basic-cli/main.roc",
	ir: "../../kaifile/ir/main.roc",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout
import ir.Ir

import Recipe
import Store

usage =
	\\usage: blu capabilities
	\\       blu build INPUT TARGET
	\\       blu shell INPUT TARGET [-- ARGV...]
	\\       blu switch INPUT TARGET
	\\       blu rollback | generations | gc
	\\INPUT is kai-ir:FILE or blu:DIR

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args|
	match run!(args.map(OsStr.display)) {
		Ok({}) => Ok({})
		Err(Usage) => {
			Stderr.line!(usage) ?? {}
			Err(Exit(2))
		}
		Err(Unsupported(message)) => {
			Stderr.line!("blu: unsupported: ${message}") ?? {}
			Err(Exit(3))
		}
		Err(ChildExited(code)) => Err(Exit(code))
		Err(err) => {
			Stderr.line!("blu: ${Str.inspect(err)}") ?? {}
			Err(Exit(1))
		}
	}

run! = |args| {
	default = "${Env.var_str!("HOME") ?? ""}/.local/share/blu"
	home = Env.var_str!("BLU_HOME") ?? default
	store = |pkgs| Store.{ home, pkgs }
	line! = |(n, path)| Stdout.line!("${n.to_str()} ${path}")
	match args {
		["--version"] => Stdout.line!("blu 0.0.0")
		["capabilities"] =>
			Stdout.line!(
				\\blueprint 0
				\\tiers core env system store
				\\inputs kai-ir blu
				,
			)
		["build", input, target] => Stdout.line!(build!(store, input, target)?)
		["shell", input, target] => shell!(store, input, target, ["sh"])
		["shell", input, target, "--", .. as argv] =>
			shell!(store, input, target, argv)
		["switch", input, target] =>
			line!(Store.switch!(store(""), environment!(store, input, target)?)?)
		["rollback"] => line!(Store.rollback!(store(""))?)
		["generations"] => {
			{ current, list } = Store.generations!(store(""))?
			for (n, path) in list {
				suffix = if n == current " current" else ""
				Stdout.line!("${n.to_str()} ${path}${suffix}")?
			}
			Ok({})
		}
		["gc"] => {
			for path in Store.gc!(store(""))? {
				Stdout.line!(path)?
			}
			Ok({})
		}
		_ => Err(Usage)
	}
}

## A kai-ir build runs over a snapshot of the working directory; a blu target
## is a recipe in the input directory.
build! = |store, input, target|
	match source!(store, input)? {
		(s, KaiIr(ir)) => {
			root = Env.cwd!()?.display()
			snapshot = Store.import!(s, root, "source")?
			recipe = Recipe.build(ir, target, snapshot).map_err(unsupported)?
			Store.realise!(s, recipe, [])
		}
		(s, Native) => Store.realise!(s, Store.load!(s, target)?, [])
	}

## The environment's bin is the whole PATH; the terminal's identity survives.
shell! = |store, input, target, argv| {
	env = environment!(store, input, target)?
	(program, rest) = match argv {
		[first, .. as others] => (first, others)
		[] => return Err(Usage)
	}
	var $keep = [("PATH", "${env}/bin")]
	names : List(Str)
	names = ["HOME", "TERM", "USER"]
	for name in names {
		match Env.var_str!(OsStr.from_str(name)) {
			Ok(value) => {
				$keep = $keep.append((name, value))
			}
			Err(_) => {}
		}
	}
	code = Cmd.new_str(program)
		.args_str(rest)
		.clear_envs()
		.envs_str($keep)
		.exec_exit_code!()?
	if code == 0 Ok({}) else Err(ChildExited(code))
}

## A kai-ir target is an environment; a blu target is one recipe.
environment! = |store, input, target|
	match source!(store, input)? {
		(s, KaiIr(ir)) =>
			Store.realise!(
				s,
				Recipe.environment(ir, target).map_err(unsupported)?,
				[],
			)
		(s, Native) => Store.realise!(s, Store.load!(s, target)?, [])
	}

## kai-ir tools resolve against $BLU_PKGS; a blu input is the package directory.
source! = |store, input|
	match input.split_on(":") {
		["kai-ir", file] => {
			text = Path.unix(file).read_utf8!()?
			ir = Ir.parse(text).map_err(|err| BadIr(Str.inspect(err)))?
			pkgs = Env.var_str!("BLU_PKGS")
				.map_err(|_| Unsupported("kai-ir needs BLU_PKGS"))?
			Ok((store(pkgs), KaiIr(ir)))
		}
		["blu", dir] => Ok((store(dir), Native))
		_ => Err(Unsupported("input ${input}"))
	}

unsupported : Str -> [Unsupported(Str)]
unsupported = |message| Unsupported(message)
