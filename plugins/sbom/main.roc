## The sbom plugin: `kai sbom`, SBOMs of a project's releases from its std
## settings and lock. Sbom.roc plans each action; Inputs.roc names the
## project's inputs; Profile.roc and the format modules beside it inspect
## compositions and render, read and check SPDX and CycloneDX documents.
package
	[Sbom]
	{
		pf: platform "../../platform/main.roc",
		std: "../std/main.roc",
	}

import Cases
import Release
import Sbom
import pf.Conformance

# Sbom.roc's planning tests cover the implementation.
expect Conformance.missing(
	Sbom.plugin([Name("x")]),
	[{ command: "sbom", backend: "" }],
) == []
