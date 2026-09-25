# Blu recipes: the pure data a .blu file holds, and the kai-ir environments
# and builds that become recipes.
import ir.Ir
import ir.Project
import ir.Sexpr

## Inputs name other recipes in the package directory.
Recipe := { name : Str, inputs : List(Str), build : Build }.{

	Build : [
		Fetch({ url : Str, sha256 : Str, path : Str }),
		Run(List(Str)),
		Union,
		Project({ source : Str, run : List(Str), output : Str }),
	]

	parse : Str -> Try(Recipe, Str)
	parse = |text| {
		wire : { name : Str, inputs : Try(List(Str), [Missing]), build : Build }
		wire = Sexpr.parse(text).map_err(Str.inspect)?
		inputs = wire.inputs ?? []
		recipe = Recipe.{ name: wire.name, inputs, build: wire.build }
		match recipe.build {
			Fetch({ path, .. }) if !Project.valid_output(path) =>
				Err("fetch path must be relative and normalized: ${path}")
			Project(_) => Err("Project builds come only from kai-ir")
			_ => Ok(recipe)
		}
	}

	## The realisation key's text: the recipe with its inputs resolved to paths.
	key : Recipe, List(Str) -> Str
	key = |recipe, paths|
		Sexpr.to_str({ name: recipe.name, inputs: paths, build: recipe.build })

	## A kai-ir environment is the Union of its default-source tools.
	environment : Ir, Str -> Try(Recipe, Str)
	environment = |ir, name| {
		project = Project.validate(ir)?
		env = project.environments.find_first(|e| e.name == name)
			.map_err(|_| "unknown environment: ${name}")?
		if !env.overlays.is_empty() {
			return Err("blu does not support overlays in environment ${name}")
		}
		for t in env.tools {
			match project.sources.find_first(|s| s.name == t.source) {
				Ok({ provider: Auto, .. }) => {}
				_ => return Err("blu has no source ${t.source} for tool ${t.name}")
			}
		}
		inputs = env.tools.map(|t| t.name)
		Ok(Recipe.{ name: "env-${name}", inputs, build: Union })
	}

	## A kai-ir build runs its argv over SOURCE, the imported project snapshot.
	build : Ir, Str, Str -> Try(Recipe, Str)
	build = |ir, name, source| {
		project = Project.validate(ir)?
		b = project.builds.find_first(|x| x.name == name)
			.map_err(|_| "unknown build: ${name}")?
		if !b.inputs.is_empty() or !b.needs.is_empty() {
			return Err("blu does not support build inputs or needs: ${name}")
		}
		env = Recipe.environment(project, b.environment)?
		project_build = Project({ source, run: b.run, output: b.output })
		Ok(Recipe.{ name, inputs: env.inputs, build: project_build })
	}
}
