# SBOMs of a release with the sbom plugin: `kai sbom` inventories a reviewed
# composition, composition.json, against what this project downloads and
# declares, and writes SPDX and CycloneDX sidecars of a release file.
#
#     kai sbom inputs     # the inputs composition.json disposes of
#     kai sbom pins       # the locked downloads, for supplier SBOM fetchers
#     kai sbom inspect --composition composition.json --output inventory.json \
#       -- source
#     kai sbom bind --inventory inventory.json --subject subject.json \
#       --context context.json --artifact greeting.tar.zst
#     kai sbom check --manifest greeting.tar.zst.sbom-manifest.json \
#       --inventory inventory.json
#
# `path` is a dependency fetched by its published SHA-256 on every
# system, a file source (`source:path`); `jq` is a program per system, here
# pinned by its SHA-256 (`program:jq:<system>`); the task is `task:check`.
# subject.json states the release file's digest and size, which kai never
# reads, and context.json the documents' namespace, author and generator.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	sbom: "../../plugins/sbom/main.roc",
	std: "../../plugins/std/main.roc",
}

import pf.Kaifile
import std.Config
import std.Std
import sbom.Sbom

releases = "https://github.com/roc-lang/path/releases/download/4.0.0"

jq = "https://github.com/jqlang/jq/releases/download/jq-1.7.1"

project : List(Config.Setting)
project = [
	Name("greeting"),
	Systems(["x86_64-linux"]),
	FetchAll(
		"path",
		{
			url: "${releases}/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
			sha256: "435499c7ffb4f357d2956e3bb2802a81264f6f2f50c896c9913fb86f7bc752bb",
		},
	),
	Fetch(
		"jq",
		[
			{
				system: "x86_64-linux",
				url: "${jq}/jq-linux-amd64",
				sha256: "5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5",
			},
		],
	),
	Environment("dev", [Tools(["jq#jq"])]),
	Task("check", [Use("dev"), Run(["jq", "--version"])]),
]

kaifile = Kaifile.new([Std.plugin(project), Sbom.plugin(project)])
