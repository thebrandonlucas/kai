# Pure Guix shell planning: one environment's tools become exact
# `guix shell --pure` argv. Kai supports no other Guix operation.
import ir.Ir
import ir.Project
import ir.Request

## Tool names are native Guix specifications, never translated from Nix
## names. Every Guix source means the installed Guix channels; Kai's lock
## does not pin them.
GuixBackend :: [].{
	plan : Ir, Request -> Try(List(Str), Str)
	plan = |ir, request| {
		(name, command) = match request {
			Request.Shell(shell, argv) => (shell, argv)
			_ => return Err("Guix supports only kai shell")
		}
		project = Project.validate(ir)?
		shell = project.shells.find_first(|s| s.name == name)
			.map_err(|_| "unknown shell: ${name}")?
		Project.check_environment(project, Guix, shell.environment)?
		environment = project.environments.find_first(
			|e| e.name == shell.environment,
		).map_err(|_| "unknown environment: ${shell.environment}")?
		# Without specifications, guix shell would load a manifest from the
		# working directory instead.
		if environment.tools.is_empty() {
			return Err("a Guix shell needs at least one tool: ${environment.name}")
		}
		specs = environment.tools.map(|t| t.name)
		# A leading "-" would make a specification a guix option.
		if specs.any(|spec| spec.starts_with("-")) {
			return Err("invalid Guix tool in environment ${environment.name}")
		}
		tail = if command.is_empty() [] else ["--"].concat(command)
		Ok(["guix", "shell", "--pure"].concat(specs).concat(tail))
	}
}

fixture : List(Ir.Environment) -> Ir
fixture = |environments| {
	..Ir.empty("guix tests"),
	systems: ["x86_64-linux"],
	sources: [
		{ name: "nix", provider: NixPackages("github:NixOS/nixpkgs") },
		{ name: "guix", provider: GuixPackages("channels") },
	],
	inputs: [{ name: "patch", url: "github:example/patch", kind: Overlay }],
	environments,
	shells: environments.map(|e| { name: e.name, environment: e.name }),
}

env : Str, List(Str) -> Ir.Environment
env = |name, tools| {
	name,
	parents: [],
	tools: tools.map(|text| Project.tool(text) ?? { source: "", name: text }),
	overlays: [],
}

check : List(Ir.Environment), Request, Try(List(Str), {}) -> Bool
check = |environments, request, expected|
	match (GuixBackend.plan(fixture(environments), request), expected) {
		(Ok(argv), Ok(want)) => argv == want
		(Err(_), Err({})) => Bool.True
		_ => Bool.False
	}

# Inherited and named-source tools are native specifications, passed as
# exact argv; a command follows --, arguments unchanged.
expect [
	(
		Request.Shell("dev", []),
		Ok(["guix", "shell", "--pure", "git", "hello@2.12:out"]),
	),
	(
		Request.Shell("dev", ["hello", "--greeting", "two words", ""]),
		Ok([
			"guix",
			"shell",
			"--pure",
			"git",
			"hello@2.12:out",
			"--",
			"hello",
			"--greeting",
			"two words",
			"",
		]),
	),
].all(
	|(request, expected)|
		check(
			[
				env("base", ["git"]),
				{ ..env("dev", ["guix#hello@2.12:out"]), parents: ["base"] },
			],
			request,
			expected,
		),
)

# Nix-only data, empty tool lists and non-shell operations are refused.
expect [
	([env("dev", ["nix#hello"])], Request.Shell("dev", [])),
	([env("dev", ["python3Packages.requests'"])], Request.Shell("dev", [])),
	([{ ..env("dev", ["hello"]), overlays: ["patch"] }], Request.Shell("dev", [])),
	([env("dev", [])], Request.Shell("dev", [])),
	([env("dev", ["-L"])], Request.Shell("dev", [])),
	([env("dev", ["hello"])], Request.Shell("missing", [])),
	([env("dev", ["hello"])], Request.Run("dev", [])),
	([env("dev", ["hello"])], Request.Build("dev")),
	([env("dev", ["hello"])], Request.Workflow("dev")),
	([env("dev", ["hello"])], Request.Generate),
].all(|(environments, request)| check(environments, request, Err({})))
