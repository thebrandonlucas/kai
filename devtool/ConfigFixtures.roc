# Kaifile.roc configurations that `roc check` must accept or reject at compile
# time, plus the semantic IR that equivalent configurations must share.
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout

ConfigFixtures := [].{
	Expected : [Valid, Rejected(Str), RejectedName(Str)]

	Fixture : { name : Str, body : Str, expected : Expected }

	composition_header =
		\\app [config] { pf: platform "../../kaifile/platform/main.roc" }

	# The same builds inline and through an imported helper module.
	build_settings =
		\\Build("app", [Use("builder"), Inputs(["assets"]), Needs(["library"]),
		\\  Run(["python3", "build.py", "", "two words", "$HOME"]),
		\\  Output("dist/app")]),
		\\ Build("library", [Use("builder"), Run(["python3", "library.py"]),
		\\  Output("dist/library")])

	build_base =
		\\Name("builds"), Environment("builder", []),
		\\ Source("assets", "path:./assets")

	# Typed workflow references preserve argv and repeated operations.
	workflow_base =
		\\Name("workflows"), Environment("dev", []),
		\\ Task("check.all", [Use("dev"), Run(["true"])]),
		\\ Build("app", [Use("dev"), Run(["true"]), Output("out")])

	workflow_steps =
		\\Workflow("ci", [RunWorkflow("leaf"), BuildArtifact("app"),
		\\  RunWorkflow("leaf"), BuildArtifact("app")]),
		\\ Workflow("leaf", [RunTask("check.all", ["", "two words",
		\\  "\\"quoted\\"", "$HOME", "line\\nbreak", "--flag"])])

	helper_modules = [
		{
			name: "ProjectBuilds",
			source: \\import pf.Config
				\\ProjectBuilds :: [].{
				\\ settings : List(Config.Setting)
				\\ settings = [${ConfigFixtures.build_settings}]
				\\}
			,
		},
		{
			name: "ProjectWorkflows",
			source: \\# Reusable typed workflows compose as ordinary settings.
				\\import pf.Config
				\\ProjectWorkflows :: [].{
				\\ settings : List(Config.Setting)
				\\ settings = [${ConfigFixtures.workflow_steps}]
				\\}
			,
		},
	]

	fixtures : List(Fixture)
	fixtures = [
		{
			name: "Valid",
			expected: Valid,
			body: \\config = [Name("valid"), Environment("dev", [Tools(["git"])]),
				\\ Shell("default", [Use("dev")])]
			,
		},
		{
			name: "ExplicitAuto",
			expected: Valid,
			body: \\config = [Name("auto"), Packages("default", Auto),
				\\ Environment("dev", [Tools(["hello@2.12.1", "glibc:debug"])]),
				\\ Shell("default", [Use("dev")])]
			,
		},
		{
			name: "ExplicitNix",
			expected: Valid,
			body: \\config = [Name("nix"), Packages("default",
				\\  From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))),
				\\ Environment("dev",
				\\  [Tools(["python3Packages.requests", "7zip", "2bwm"])]),
				\\ Shell("default", [Use("dev")])]
			,
		},
		{
			name: "ExplicitGuix",
			expected: Valid,
			body: \\config = [Name("guix"), Packages("guix",
				\\  From(GuixPackages("https://git.savannah.gnu.org/git/guix.git"))),
				\\ Environment("dev",
				\\  [Tools(["guix#hello@2.12.1", "guix#glibc:debug"])]),
				\\ Shell("default", [Use("dev")])]
			,
		},
		{
			name: "ForwardInheritance",
			expected: Valid,
			body: \\config = [Name("inheritance"),
				\\ Overlay("tools", "github:roc-lang/roc-overlay"),
				\\ Environment("dev", [Extend("base"), Tools(["python3", "git"]),
				\\  Overlays(["tools"])]),
				\\ Environment("base", [Tools(["git"]), Overlays(["tools"])]),
				\\ Environment("alias", [Extend("dev"), Overlays([])]),
				\\ Environment("empty", []), Shell("default", [Use("alias")]),
				\\ Task("check.version", [Use("dev"), Run(["git", "--version"])])]
			,
		},
		{
			name: "TasksWithoutShells",
			expected: Valid,
			body: \\config = [Name("tasks"), Environment("dev", [Tools(["git"])]),
				\\ Task("check", [Use("dev"), Run(["git", "--version"])])]
			,
		},
		{
			name: "EquivalentInline",
			expected: Valid,
			body: \\config = [Name("inheritance"),
				\\ Overlay("tools", "github:roc-lang/roc-overlay"),
				\\ Environment("dev", [Tools(["git", "python3"]),
				\\  Overlays(["tools"])]),
				\\ Environment("base", [Tools(["git"]), Overlays(["tools"])]),
				\\ Environment("alias", [Tools(["git", "python3"]),
				\\  Overlays(["tools"])]),
				\\ Environment("empty", []), Shell("default", [Use("alias")]),
				\\ Task("check.version", [Use("dev"), Run(["git", "--version"])])]
			,
		},
		{
			name: "EquivalentDefault",
			expected: Valid,
			body: \\config = [Name("valid"), Packages("default", Auto),
				\\ Environment("dev", [Tools(["git"])]),
				\\ Shell("default", [Use("dev")])]
			,
		},
		{
			name: "EquivalentComposition",
			expected: Valid,
			body: \\config = [Name("composed"), Systems(["x86_64-linux"]),
				\\ Environment("base", [Tools(["git"])]),
				\\ Environment("dev", [Tools(["git", "python3"])]),
				\\ Shell("default", [Use("dev")]),
				\\ Task("fmt", [Use("dev"), Run(["python3", "--version"])]),
				\\ Task("test", [Use("dev"), Run(["git", "--version"])]),
				\\ Task("args", [Use("dev"), Run(["python3", "-c",
				\\  "import json, sys; print(json.dumps(sys.argv[1:]))",
				\\  "configured argument"])])]
			,
		},
		{
			name: "MissingName",
			expected: Rejected("MissingName"),
			body: "config = [Environment(\"dev\", [])]",
		},
		{
			name: "DuplicateName",
			expected: Rejected("DuplicateName"),
			body: "config = [Name(\"one\"), Name(\"two\")]",
		},
		{
			name: "DuplicateSystems",
			expected: Rejected("DuplicateSystems"),
			body: \\config = [Name("duplicate"), Systems(["x86_64-linux"]),
				\\ Systems(["aarch64-linux"])]
			,
		},
		{
			name: "NoSystems",
			expected: Rejected("no systems"),
			body: "config = [Name(\"invalid\"), Systems([])]",
		},
		{
			name: "InvalidName",
			expected: Rejected("invalid name"),
			body: "config = [Name(\"\")]",
		},
		{
			name: "DuplicateShell",
			expected: Rejected("DuplicateShell"),
			body: \\config = [Name("duplicate"), Environment("dev", []),
				\\ Shell("default", [Use("dev")]), Shell("default", [Use("dev")])]
			,
		},
		{
			name: "DuplicateEnvironment",
			expected: Rejected("DuplicateEnvironment"),
			body: \\config = [Name("duplicate"), Environment("dev", []),
				\\ Environment("dev", [])]
			,
		},
		{
			name: "DuplicateTask",
			expected: Rejected("DuplicateTask"),
			body: \\config = [Name("duplicate"), Environment("dev", []),
				\\ Task("check", [Use("dev"), Run(["git"])]),
				\\ Task("check", [Use("dev"), Run(["git"])])]
			,
		},
		{
			name: "DuplicateSource",
			expected: Rejected("DuplicateSource"),
			body: \\config = [Name("duplicate"), Packages("default", Auto),
				\\ Packages("default", Auto)]
			,
		},
		{
			name: "DuplicateInput",
			expected: Rejected("DuplicateInput"),
			body: \\config = [Name("duplicate"),
				\\ Input("tools", "github:numtide/flake-utils"),
				\\ Overlay("tools", "github:roc-lang/roc-overlay")]
			,
		},
		{
			name: "MissingShellUse",
			expected: Rejected("MissingUse"),
			body: "config = [Name(\"invalid\"), Shell(\"default\", [])]",
		},
		{
			name: "DuplicateShellUse",
			expected: Rejected("DuplicateUse"),
			body: \\config = [Name("invalid"), Environment("dev", []),
				\\ Shell("default", [Use("dev"), Use("dev")])]
			,
		},
		{
			name: "MissingTaskUse",
			expected: Rejected("MissingUse"),
			body: \\config = [Name("invalid"), Task("check", [Run(["git"])])]
			,
		},
		{
			name: "DuplicateTaskUse",
			expected: Rejected("DuplicateUse"),
			body: \\config = [Name("invalid"), Environment("dev", []),
				\\ Task("check", [Use("dev"), Use("dev"), Run(["git"])])]
			,
		},
		{
			name: "MissingRun",
			expected: Rejected("MissingRun"),
			body: \\config = [Name("invalid"), Environment("dev", []),
				\\ Task("check", [Use("dev")])]
			,
		},
		{
			name: "DuplicateRun",
			expected: Rejected("DuplicateRun"),
			body: \\config = [Name("invalid"), Environment("dev", []),
				\\ Task("check", [Use("dev"), Run(["git"]), Run(["git"])])]
			,
		},
		{
			name: "EmptyRun",
			expected: Rejected("empty argv"),
			body: \\config = [Name("invalid"), Environment("dev", []),
				\\ Task("check", [Use("dev"), Run([])])]
			,
		},
		{
			name: "EmptyExecutable",
			expected: Rejected("empty argv"),
			body: \\config = [Name("invalid"), Environment("dev", []),
				\\ Task("check", [Use("dev"), Run([""])])]
			,
		},
		{
			name: "DuplicateTools",
			expected: Rejected("DuplicateTools"),
			body: \\config = [Name("invalid"),
				\\ Environment("dev", [Tools([]), Tools([])])]
			,
		},
		{
			name: "DuplicateOverlays",
			expected: Rejected("DuplicateOverlays"),
			body: \\config = [Name("invalid"),
				\\ Environment("dev", [Overlays([]), Overlays([])])]
			,
		},
		{
			name: "DuplicateExtend",
			expected: Rejected("DuplicateExtend"),
			body: \\config = [Name("invalid"), Environment("base", []),
				\\ Environment("dev", [Extend("base"), Extend("base")])]
			,
		},
		{
			name: "UnknownShellEnvironment",
			expected: Rejected("unknown environment"),
			body: \\config = [Name("invalid"), Shell("default", [Use("missing")])]
			,
		},
		{
			name: "UnknownTaskEnvironment",
			expected: Rejected("unknown environment"),
			body: \\config = [Name("invalid"),
				\\ Task("check", [Use("missing"), Run(["git"])])]
			,
		},
		{
			name: "UnknownParent",
			expected: Rejected("unknown environment"),
			body: \\config = [Name("invalid"),
				\\ Environment("dev", [Extend("missing")])]
			,
		},
		{
			name: "UnknownSource",
			expected: Rejected("unknown source"),
			body: \\config = [Name("invalid"),
				\\ Environment("dev", [Tools(["missing#git"])])]
			,
		},
		{
			name: "UnknownOverlay",
			expected: Rejected("unknown overlay"),
			body: \\config = [Name("invalid"),
				\\ Environment("dev", [Overlays(["missing"])])]
			,
		},
		{
			name: "FlakeIsNotOverlay",
			expected: Rejected("unknown overlay"),
			body: \\config = [Name("invalid"),
				\\ Input("utils", "github:numtide/flake-utils"),
				\\ Environment("dev", [Overlays(["utils"])])]
			,
		},
		{
			name: "InputIsNotSource",
			expected: Rejected("unknown source"),
			body: \\config = [Name("invalid"),
				\\ Input("utils", "github:numtide/flake-utils"),
				\\ Environment("dev", [Tools(["utils#git"])])]
			,
		},
		{
			name: "SelfCycle",
			expected: Rejected("environment cycle"),
			body: \\config = [Name("invalid"), Environment("dev", [Extend("dev")])]
			,
		},
		{
			name: "EnvironmentCycle",
			expected: Rejected("environment cycle"),
			body: \\config = [Name("invalid"), Environment("one", [Extend("two")]),
				\\ Environment("two", [Extend("three")]),
				\\ Environment("three", [Extend("one")])]
			,
		},
		{
			name: "InvalidNixTool",
			expected: Rejected("invalid Nix tool"),
			body: \\config = [Name("invalid"), Packages("default",
				\\  From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))),
				\\ Environment("dev", [Tools(["hello@2.12.1"])])]
			,
		},
		{
			name: "InvalidGuixTool",
			expected: Rejected("invalid Guix tool"),
			body: \\config = [Name("invalid"), Packages("default",
				\\  From(GuixPackages("https://git.savannah.gnu.org/git/guix.git"))),
				\\ Environment("dev", [Tools(["git@"])])]
			,
		},
		{
			name: "Builds",
			expected: Valid,
			body: \\config = [${ConfigFixtures.build_base},
				\\ ${ConfigFixtures.build_settings}]
			,
		},
		{
			name: "SourcesOnly",
			expected: Valid,
			body: \\config = [Name("sources"),
				\\ Source("assets", "github:example/assets")]
			,
		},
		{
			name: "BuildNoSources",
			expected: Valid,
			body: \\config = [Name("build"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Run(["true"]),
				\\  Output("dist/app")])]
			,
		},
		{
			name: "DuplicateBuildSource",
			expected: Rejected("DuplicateBuildSource"),
			body: \\config = [Name("bad"), Source("assets", "path:./assets"),
				\\ Source("assets", "path:./other")]
			,
		},
		{
			name: "SourceInputCollision",
			expected: Rejected("DuplicateInput"),
			body: \\config = [Name("bad"), Source("assets", "path:./assets"),
				\\ Input("assets", "github:example/assets")]
			,
		},
		{
			name: "SourcePackageCollision",
			expected: Rejected("DuplicateInput"),
			body: \\config = [Name("bad"), Source("assets", "path:./assets"),
				\\ Packages("assets", Auto)]
			,
		},
		{
			name: "SourceDefaultCollision",
			expected: Rejected("DuplicateInput"),
			body: \\config = [Name("bad"), Source("default", "path:./assets")]
			,
		},
		{
			name: "DuplicateBuild",
			expected: Rejected("DuplicateBuild"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Run(["true"]), Output("out")]),
				\\ Build("app", [Use("builder"), Run(["true"]), Output("out")])]
			,
		},
		{
			name: "MissingBuildUse",
			expected: Rejected("MissingUse"),
			body: \\config = [Name("bad"),
				\\ Build("app", [Run(["true"]), Output("out")])]
			,
		},
		{
			name: "MissingBuildRun",
			expected: Rejected("MissingRun"),
			body: \\config = [Name("bad"),
				\\ Build("app", [Use("builder"), Output("out")])]
			,
		},
		{
			name: "MissingBuildOutput",
			expected: Rejected("MissingOutput"),
			body: \\config = [Name("bad"),
				\\ Build("app", [Use("builder"), Run(["true"])])]
			,
		},
		{
			name: "DuplicateBuildUse",
			expected: Rejected("DuplicateUse"),
			body: \\config = [Name("bad"), Build("app", [Use("builder"),
				\\ Use("builder"), Run(["true"]), Output("out")])]
			,
		},
		{
			name: "DuplicateBuildRun",
			expected: Rejected("DuplicateRun"),
			body: \\config = [Name("bad"), Build("app", [Use("builder"),
				\\ Run(["true"]), Run(["true"]), Output("out")])]
			,
		},
		{
			name: "DuplicateBuildOutput",
			expected: Rejected("DuplicateOutput"),
			body: \\config = [Name("bad"), Build("app", [Use("builder"),
				\\ Run(["true"]), Output("out"), Output("out")])]
			,
		},
		{
			name: "DuplicateBuildInputs",
			expected: Rejected("DuplicateInputs"),
			body: \\config = [Name("bad"), Build("app", [Use("builder"),
				\\ Inputs([]), Inputs([]), Run(["true"]), Output("out")])]
			,
		},
		{
			name: "DuplicateBuildNeeds",
			expected: Rejected("DuplicateNeeds"),
			body: \\config = [Name("bad"), Build("app", [Use("builder"),
				\\ Needs([]), Needs([]), Run(["true"]), Output("out")])]
			,
		},
		{
			name: "UnknownBuildEnvironment",
			expected: Rejected("unknown environment"),
			body: \\config = [Name("bad"),
				\\ Build("app", [Use("missing"), Run(["true"]), Output("out")])]
			,
		},
		{
			name: "UnknownBuildInput",
			expected: Rejected("unknown build source"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Inputs(["missing"]),
				\\  Run(["true"]), Output("out")])]
			,
		},
		{
			name: "PackageIsNotBuildSource",
			expected: Rejected("unknown build source"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Inputs(["default"]),
				\\  Run(["true"]), Output("out")])]
			,
		},
		{
			name: "UnknownBuildDependency",
			expected: Rejected("unknown build"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Needs(["missing"]),
				\\  Run(["true"]), Output("out")])]
			,
		},
		{
			name: "TaskIsNotBuildDependency",
			expected: Rejected("unknown build"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Task("library", [Use("builder"), Run(["true"])]),
				\\ Build("app", [Use("builder"), Needs(["library"]),
				\\  Run(["true"]), Output("out")])]
			,
		},
		{
			name: "BuildSelfCycle",
			expected: Rejected("build cycle"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Needs(["app"]),
				\\  Run(["true"]), Output("out")])]
			,
		},
		{
			name: "BuildCycle",
			expected: Rejected("build cycle"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Needs(["library"]),
				\\  Run(["true"]), Output("out")]),
				\\ Build("library", [Use("builder"), Needs(["app"]),
				\\  Run(["true"]), Output("out")])]
			,
		},
		{
			name: "EmptyBuildRun",
			expected: Rejected("empty argv"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Run([]), Output("out")])]
			,
		},
		{
			name: "EmptyBuildExecutable",
			expected: Rejected("empty argv"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Run([""]), Output("out")])]
			,
		},
		{
			name: "NulBuildRun",
			expected: Rejected("NUL in argv"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"),
				\\  Run(["true", Str.from_utf8([0]) ?? ""]), Output("out")])]
			,
		},
		{
			name: "DuplicateBuildInputReference",
			expected: Rejected("DuplicateBuildInput"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Source("assets", "path:./assets"),
				\\ Build("app", [Use("builder"), Inputs(["assets", "assets"]),
				\\  Run(["true"]), Output("out")])]
			,
		},
		{
			name: "DuplicateBuildNeedReference",
			expected: Rejected("DuplicateBuildDependency"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Needs(["library", "library"]),
				\\  Run(["true"]), Output("out")])]
			,
		},
		{
			name: "BuildDepth",
			expected: Rejected("build dependencies exceed 128 levels"),
			body: ConfigFixtures.build_depth(129),
		},
		{
			name: "ComposedBuilds",
			expected: Valid,
			body: \\import ProjectBuilds
				\\config = [${ConfigFixtures.build_base}]
				\\ .concat(ProjectBuilds.settings)
			,
		},
		{
			name: "Workflows",
			expected: Valid,
			body: \\config = [${ConfigFixtures.workflow_base},
				\\ ${ConfigFixtures.workflow_steps}]
			,
		},
		{
			name: "EmptyWorkflow",
			expected: Valid,
			body: "config = [Name(\"empty\"), Workflow(\"ci\", [])]",
		},
		{
			name: "BadWorkflowName",
			expected: RejectedName("invalid workflow name"),
			body: "config = [Name(\"bad\"), Workflow(\"bad/name\", [])]",
		},
		{
			name: "BadRunWorkflowName",
			expected: RejectedName("invalid workflow name"),
			body: \\config = [Name("bad"),
				\\ Workflow("ci", [RunWorkflow("bad/name")])]
			,
		},
		{
			name: "BadRunTaskName",
			expected: RejectedName("is not a task name"),
			body: \\config = [Name("bad"),
				\\ Workflow("ci", [RunTask("bad..name", [])])]
			,
		},
		{
			name: "BadArtifactName",
			expected: RejectedName("is not an input name"),
			body: \\config = [Name("bad"),
				\\ Workflow("ci", [BuildArtifact("bad/name")])]
			,
		},
		{
			name: "DuplicateWorkflow",
			expected: Rejected("DuplicateWorkflow"),
			body: \\config = [Name("bad"), Workflow("ci", []), Workflow("ci", [])]
			,
		},
		{
			name: "UnknownWorkflowTask",
			expected: Rejected("unknown task"),
			body: \\config = [${ConfigFixtures.workflow_base},
				\\ Workflow("ci", [RunTask("missing", [])])]
			,
		},
		{
			name: "UnknownWorkflowBuild",
			expected: Rejected("unknown build"),
			body: \\config = [${ConfigFixtures.workflow_base},
				\\ Workflow("ci", [BuildArtifact("missing")])]
			,
		},
		{
			name: "UnknownWorkflow",
			expected: Rejected("unknown workflow"),
			body: \\config = [${ConfigFixtures.workflow_base},
				\\ Workflow("ci", [RunWorkflow("missing")])]
			,
		},
		{
			name: "WorkflowSelfCycle",
			expected: Rejected("workflow cycle"),
			body: \\config = [Name("bad"), Workflow("ci", [RunWorkflow("ci")])]
			,
		},
		{
			name: "UnusedWorkflowCycle",
			expected: Rejected("workflow cycle"),
			body: \\config = [Name("bad"), Workflow("safe", []),
				\\ Workflow("a", [RunWorkflow("b")]),
				\\ Workflow("b", [RunWorkflow("a")])]
			,
		},
		{
			name: "WorkflowTaskIsNotBuild",
			expected: Rejected("unknown build"),
			body: \\config = [Name("bad"), Environment("dev", []),
				\\ Task("check", [Use("dev"), Run(["true"])]),
				\\ Workflow("ci", [BuildArtifact("check")])]
			,
		},
		{
			name: "WorkflowBuildIsNotTask",
			expected: Rejected("unknown task"),
			body: \\config = [${ConfigFixtures.workflow_base},
				\\ Workflow("ci", [RunTask("app", [])])]
			,
		},
		{
			name: "WorkflowNul",
			expected: Rejected("NUL in argv"),
			body: \\config = [${ConfigFixtures.workflow_base},
				\\ Workflow("ci",
				\\  [RunTask("check.all", [Str.from_utf8([0]) ?? ""])])]
			,
		},
		{
			name: "WorkflowEmptyDiamond",
			expected: Valid,
			body: ConfigFixtures.workflow_graph(128, Bool.True, Bool.False),
		},
		{
			name: "WorkflowDepth",
			expected: Rejected("workflow dependencies exceed 128 levels"),
			body: ConfigFixtures.workflow_graph(129, Bool.False, Bool.False),
		},
		{
			name: "WorkflowExpansion",
			expected: Rejected("workflow expansion exceeds 4096 atomic steps"),
			body: ConfigFixtures.workflow_graph(14, Bool.True, Bool.True),
		},
		{
			name: "WorkflowDeclarations",
			expected: Rejected("workflows exceed 1024 declarations"),
			body: ConfigFixtures.workflow_graph(1025, Bool.False, Bool.False),
		},
		{
			name: "WorkflowSteps",
			expected: Rejected("workflow graph exceeds 8192 steps"),
			body: \\config = [Name("wide"), Workflow("empty", []), Workflow("wide", {
				\\ var $steps = []
				\\ while $steps.len() <= 8192 {
				\\  $steps = $steps.append(RunWorkflow("empty"))
				\\ }
				\\ $steps
				\\})]
			,
		},
		{
			name: "WorkflowArgv",
			expected: Rejected("argv exceeds 4096 arguments"),
			body: \\config = [Name("args"), Environment("dev", []),
				\\ Task("check", [Use("dev"), Run(["true"])]),
				\\ Workflow("ci", [RunTask("check", {
				\\  var $argv = []
				\\  while $argv.len() < 4096 { $argv = $argv.append("") }
				\\  $argv
				\\ })])]
			,
		},
		{
			name: "WorkflowArgvBytes",
			expected: Rejected("workflow expansion exceeds 1 MiB argv bytes"),
			body: \\config = [${ConfigFixtures.workflow_base},
				\\ Workflow("leaf", [RunTask("check.all", {
				\\  var $arg = "x"
				\\  while $arg.to_utf8().len() < 524288 {
				\\   $arg = $arg.concat($arg)
				\\  }
				\\  [$arg]
				\\ })]),
				\\ Workflow("twice", [RunWorkflow("leaf"), RunWorkflow("leaf")])]
			,
		},
		{
			name: "ComposedWorkflows",
			expected: Valid,
			body: \\import ProjectWorkflows
				\\config = [${ConfigFixtures.workflow_base}]
				\\ .concat(ProjectWorkflows.settings)
			,
		},
		# Capability support is checked for a selected request, not globally.
		{
			name: "GuixOverlay",
			expected: Valid,
			body: \\config = [Name("deferred-capability"),
				\\ Packages("default", From(GuixPackages("current"))),
				\\ Overlay("tools", "github:example/tools"),
				\\ Environment("dev", [Tools(["git"]), Overlays(["tools"])])]
			,
		},
	].concat(ConfigFixtures.bad_outputs).concat(ConfigFixtures.bad_sources)

	bad_outputs : List(Fixture)
	bad_outputs = [
		"",
		"/absolute",
		".",
		"..",
		"dist/../escape",
		"dist//file",
		"dist/",
		"C:/file",
	].map_with_index(
		|output, index| {
			name: "BadOutput${U64.to_str(index)}",
			expected: Rejected("invalid build output"),
			body: \\config = [Name("bad"), Environment("builder", []),
				\\ Build("app", [Use("builder"), Run(["true"]),
				\\  Output("${output}")])]
			,
		},
	)

	bad_sources : List(Fixture)
	bad_sources = [
		"path:.",
		"path:./",
		"path:/absolute",
		"path:../escape",
		"path:./assets/../escape",
		"file:/absolute",
		"git+file:///absolute",
		"flake:nixpkgs",
	].map_with_index(
		|reference, index| {
			name: "BadBuildSource${U64.to_str(index)}",
			expected: Rejected("invalid build source reference"),
			body: \\config = [Name("bad"), Source("assets", "${reference}")]
			,
		},
	)

	# Each build needs the previous one, so the chain is `count` levels deep.
	build_depth : U64 -> Str
	build_depth = |count| {
		builds = List.repeat({}, count).map_with_index(
			|_, index| {
				needs = if index == 0 {
					""
				} else {
					"Needs([\"b${U64.to_str(index - 1)}\"]), "
				}
				name = "b${U64.to_str(index)}"
				step = "Run([\"true\"]), Output(\"out\")"
				"Build(\"${name}\", [Use(\"builder\"), ${needs}${step}])"
			},
		)
		settings = ["Name(\"deep\")", "Environment(\"builder\", [])"].concat(builds)
		"config = [${Str.join_with(settings, ",\n ")}]"
	}

	# Workflow `wN` runs `wN-1` once or twice; `w0` is empty or one task.
	workflow_graph : U64, Bool, Bool -> Str
	workflow_graph = |count, double, atomic| {
		workflows = List.repeat({}, count).map_with_index(
			|_, index| {
				steps = if index > 0 {
					step = "RunWorkflow(\"w${U64.to_str(index - 1)}\")"
					if double [step, step] else [step]
				} else if atomic {
					["RunTask(\"check\", [])"]
				} else {
					[]
				}
				name = "w${U64.to_str(index)}"
				"Workflow(\"${name}\", [${Str.join_with(steps, ", ")}])"
			},
		)
		settings = [
			"Name(\"graph\")",
			"Environment(\"dev\", [])",
			"Task(\"check\", [Use(\"dev\"), Run([\"true\"])])",
		].concat(workflows)
		"config = [${Str.join_with(settings, ",\n ")}]"
	}

	# IR pairs that must print byte-identical semantic IR.
	equivalent_ir = [
		("ForwardInheritance", "EquivalentInline"),
		("Valid", "EquivalentDefault"),
		("Composed", "EquivalentComposition"),
		("Builds", "ComposedBuilds"),
		("Workflows", "ComposedWorkflows"),
	]

	workflow_argv_ir =
		\\("" "two words" "\\"quoted\\"" "$HOME" "line\\nbreak" "--flag")

	# New optional fields must carry feature markers for old consumers.
	ir_markers = [
		{
			name: "Builds",
			texts: [
				"(minor 2)",
				"(requires (\"sources\" \"builds\"))",
				"(build_sources ",
				"(builds ",
			],
		},
		{
			name: "Workflows",
			texts: [
				"(minor 2)",
				"(requires (\"builds\" \"workflows\"))",
				"(workflows ",
				"(RunTask \"check.all\" ${ConfigFixtures.workflow_argv_ir})",
			],
		},
	]

	# Relative path from absolute directory `from` to absolute path `to`.
	relative : Str, Str -> Str
	relative = |from, to| {
		from_parts = from.split_on("/").keep_if(|part| !part.is_empty())
		to_parts = to.split_on("/").keep_if(|part| !part.is_empty())
		var $common = 0
		var $matching = Bool.True
		for part in from_parts {
			if $matching and (to_parts.get($common) ?? "") == part {
				$common = $common + 1
			} else {
				$matching = Bool.False
			}
		}
		parents = List.repeat("..", from_parts.len() - $common)
		Str.join_with(parents.concat(to_parts.drop_first($common)), "/")
	}

	accepts : Expected, [Exited(I32), Signaled(I32)], Str -> Bool
	accepts = |expected, status, log| {
		(code, texts) = match expected {
			Valid => (0, [])
			Rejected(message) => (
				1,
				["compile time crash", "Invalid Kaifile.roc:", message],
			)
			RejectedName(message) => (1, ["invalid string", message])
		}
		match status {
			Exited(actual) => actual == code and texts.all(|text| log.contains(text))
			Signaled(_) => Bool.False
		}
	}

	run! = || {
		root = Path.canonicalize!(Env.cwd!()?)?
		roc = ConfigFixtures.find_roc!()?
		temporary = Env.create_temp_dir_with_prefix!("kai-config-fixtures-")?
		workspace = Path.canonicalize!(temporary)?
		result = ConfigFixtures.run_in!(root, roc, workspace)
		Path.delete_all!(workspace)?
		result
	}

	# Resolve `roc` once so the empty-PATH run still finds the compiler.
	find_roc! = || {
		for directory in Env.var_str!("PATH")?.split_on(":") {
			candidate = Path.join(Path.utf8(directory), "roc")
			if !directory.is_empty() and Path.is_file!(candidate)? {
				return Ok(candidate)
			}
		}
		Err(RocNotFound)
	}

	run_in! = |root, roc, workspace| {
		# Evaluating an app needs a relative platform path.
		platform_path = ConfigFixtures.relative(
			Path.display(workspace),
			Path.display(Path.join(root, "kaifile/platform/main.roc")),
		)
		composition = Path.join(root, "examples/composition")
		kaifile = Path.read_utf8!(Path.join(composition, "Kaifile.roc"))?
		composed = match kaifile.split_on(ConfigFixtures.composition_header) {
			[before, after] => "${before}${after}"
			_ => return Err(UnexpectedCompositionHeader(kaifile))
		}
		tasks = Path.read_utf8!(Path.join(composition, "ProjectTasks.roc"))?
		helpers = ConfigFixtures.helper_modules.append(
			{ name: "ProjectTasks", source: tasks },
		)
		apps = ConfigFixtures.fixtures.append(
			{ name: "Composed", body: composed, expected: Valid },
		)
		for helper in helpers {
			Path.write_utf8!(
				Path.join(workspace, "${helper.name}.roc"),
				helper.source,
			)?
		}
		header = "app [config] { pf: platform \"${platform_path}\" }"
		for fixture in apps {
			Path.write_utf8!(
				Path.join(workspace, "${fixture.name}.roc"),
				"${header}\n\n${fixture.body}\n",
			)?
		}
		for fixture in apps {
			ConfigFixtures.check!(roc, workspace, fixture)?
		}
		for (left, right) in ConfigFixtures.equivalent_ir {
			ConfigFixtures.same_ir!(roc, workspace, left, [], right, [])?
		}
		# Tool availability must not affect semantic configuration.
		no_tools = Path.join(workspace, "no-tools")
		Path.create_dir!(no_tools)?
		ConfigFixtures.same_ir!(
			roc,
			workspace,
			"Valid",
			[],
			"Valid",
			[("PATH", Path.display(no_tools))],
		)?
		for marker in ConfigFixtures.ir_markers {
			ir = ConfigFixtures.ir!(roc, workspace, marker.name, [])?
			for text in marker.texts {
				if !ir.contains(text) {
					Stderr.line!(ir)?
					return Err(MissingIrMarker({ fixture: marker.name, text }))
				}
			}
		}
		count = |expected|
			apps.keep_if(
				|fixture|
					match (fixture.expected, expected) {
						(Valid, Valid) => Bool.True
						(Rejected(_), Rejected(_)) => Bool.True
						(RejectedName(_), RejectedName(_)) => Bool.True
						_ => Bool.False
					},
			).len()
		valid = U64.to_str(count(Valid))
		semantic = U64.to_str(count(Rejected("")))
		named = U64.to_str(count(RejectedName("")))
		rejected = "${semantic} semantic errors and ${named} checked-name errors"
		Stdout.line!(
			Str.join_with(
				[
					"${valid} valid configs accepted",
					"${rejected} rejected at compile time",
					"equivalent IR verified",
				],
				"; ",
			),
		)
	}

	roc_command = |roc, args|
		Cmd.new(Path.to_os_str(roc)).args(args).timeout_ms(300_000)

	check! = |roc, workspace, fixture| {
		path = Path.join(workspace, "${fixture.name}.roc")
		output = ConfigFixtures.roc_command(
			roc,
			[OsStr.utf8("check"), Path.to_os_str(path)],
		).merge_stderr(Bool.True).run!()?
		log = Str.from_utf8_lossy(output.stdout_bytes)
		if ConfigFixtures.accepts(fixture.expected, output.status, log) {
			Ok({})
		} else {
			Stderr.line!(log)?
			Err(
				UnexpectedCheck({
					fixture: fixture.name,
					expected: fixture.expected,
					status: output.status,
				}),
			)
		}
	}

	ir! = |roc, workspace, name, envs| {
		path = Path.join(workspace, "${name}.roc")
		output = ConfigFixtures.roc_command(roc, [Path.to_os_str(path)])
			.envs_str(envs)
			.run!()?
		ir = Str.from_utf8_lossy(output.stdout_bytes)
		match output.status {
			Exited(0) => Ok(ir)
			_ => {
				Stderr.line!(Str.from_utf8_lossy(output.stderr_bytes))?
				Err(IrFailed({ fixture: name, status: output.status }))
			}
		}
	}

	same_ir! = |roc, workspace, left, left_envs, right, right_envs| {
		left_ir = ConfigFixtures.ir!(roc, workspace, left, left_envs)?
		right_ir = ConfigFixtures.ir!(roc, workspace, right, right_envs)?
		if left_ir == right_ir {
			Ok({})
		} else {
			Stderr.line!("${left}:\n${left_ir}\n${right}:\n${right_ir}")?
			Err(DifferentIr({ left, right }))
		}
	}
}
