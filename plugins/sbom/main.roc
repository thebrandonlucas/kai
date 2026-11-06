## roc-blueprint's SBOM profile, ported for Kai's sbom plugin: Profile.roc
## inspects a reviewed composition against a project's inputs and renders
## the inventory as SPDX 3.0.1, SPDX 2.3 and CycloneDX 1.7; Spdx3.roc,
## Spdx2.roc and CycloneDx.roc check and read those formats; Sidecar.roc and
## Manifest.roc check written sidecars and their evidence manifest.
package [Manifest, Profile, Sidecar] {}

import Cases
