# Environments select ordered overlay stacks; Extend applies the parent's first.
app [config] { pf: platform "../../kaifile/platform/main.roc" }

config = [
	Name("overlays"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Overlay("base", "path:./overlays/base"),
	Overlay("patch", "path:./overlays/patch"),
	Environment("base", [Tools(["fixtureTool"]), Overlays(["base"])]),
	Environment("forward", [Tools(["fixtureTool"]), Overlays(["base", "patch"])]),
	Environment("reversed", [Tools(["fixtureTool"]), Overlays(["patch", "base"])]),
	Environment("plain", [Tools(["fixtureTool"])]),
	Environment("dev", [Extend("base"), Tools(["hello"]), Overlays(["patch"])]),
	Shell("default", [Use("dev")]),
	Shell("base", [Use("base")]),
	Shell("forward", [Use("forward")]),
	Shell("reversed", [Use("reversed")]),
	Shell("plain", [Use("plain")]),
	Task("greet", [Use("dev"), Run(["hello", "--greeting"])]),
]
