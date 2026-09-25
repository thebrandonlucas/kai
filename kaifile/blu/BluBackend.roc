# Pure blu planning: a shell, task or build request becomes one blu
# Blueprint command over the staged kai-ir. blu validates the project itself.
import ir.Ir
import ir.Plan
import ir.Request

BluBackend :: [].{

	## FILE is where the executor stages the IR; kai-ir targets environments
	## for shell and builds for build.
	plan : Ir, Request, Str -> Try(Plan, Str)
	plan = |ir, request, file| {
		input = "kai-ir:${file}"
		environment = |found, kind, name|
			found.map_ok(|x| x.environment).map_err(|_| "unknown ${kind}: ${name}")
		(action, argv) = match request {
			Request.Shell(name, command) => {
				shell = ir.shells.find_first(|s| s.name == name)
				env = environment(shell, "shell", name)?
				tail = if command.is_empty() [] else ["--"].concat(command)
				(Shell(name), ["blu", "shell", input, env].concat(tail))
			}
			Request.Run(name, args) => {
				task = ir.tasks.find_first(|t| t.name == name)
				env = environment(task, "task", name)?
				run = task.map_ok(|t| t.run) ?? []
				(Run(name), ["blu", "shell", input, env, "--"].concat(run).concat(args))
			}
			Request.Build(name) => (Build(name), ["blu", "build", input, name])
			_ => return Err("blu supports only kai shell, run and build")
		}
		artifacts = match request {
			Request.Build(name) => {
				b = ir.builds.find_first(|x| x.name == name)
					.map_err(|_| "unknown build: ${name}")?
				[{ name, installable: input, output: b.output, dependencies: [] }]
			}
			_ => []
		}
		files = [{ path: file, contents: ir.to_str() }]
		step = { action, files, argv, artifacts, operations: [] }
		Ok(Plan.{ steps: [step] })
	}
}

fixture : Ir
fixture = {
	..Ir.empty("blu tests"),
	tasks: [{ name: "hi", environment: "dev", run: ["hello"] }],
	shells: [{ name: "default", environment: "dev" }],
	builds: [
		{
			name: "app",
			environment: "dev",
			inputs: [],
			needs: [],
			run: ["make"],
			output: "out",
		},
	],
}

argv : Request -> Try(List(Str), {})
argv = |request|
	match BluBackend.plan(fixture, request, "/ir") {
		Ok(plan) => plan.steps.first().map_ok(|s| s.argv).map_err(|_| {})
		Err(_) => Err({})
	}

# Shells and tasks run in their environment; builds name the Kaifile build.
expect [
	(Request.Shell("default", []), Ok(["blu", "shell", "kai-ir:/ir", "dev"])),
	(
		Request.Shell("default", ["ls"]),
		Ok(["blu", "shell", "kai-ir:/ir", "dev", "--", "ls"]),
	),
	(
		Request.Run("hi", ["x"]),
		Ok(["blu", "shell", "kai-ir:/ir", "dev", "--", "hello", "x"]),
	),
	(Request.Build("app"), Ok(["blu", "build", "kai-ir:/ir", "app"])),
	(Request.Shell("missing", []), Err({})),
	(Request.Workflow("ci"), Err({})),
].all(|(request, expected)| argv(request) == expected)
