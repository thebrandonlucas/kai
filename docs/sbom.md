# `kai sbom`: SBOMs of a release

The sbom plugin, `plugins/sbom`, writes the software bill of materials of a
release file from what the project's Kaifile declares and its lock pins:
SPDX 3.0.1, SPDX 2.3 and CycloneDX 1.7 sidecars, and an evidence manifest
that lists them. A maintainer reviews a *composition* (what the release
holds and depends on, and what became of every input); `kai sbom inspect`
checks it against the project and writes an *inventory*; `kai sbom bind`
renders the inventory for one release file; `kai sbom check` holds the
sidecars to the profile, the inventory, the manifest and the release file.

The documents follow roc-blueprint's SBOM profile, `blueprint-spdx-3.0-v2`:
the same compositions, inventories, identities and renderings, so a project
moving from roc-blueprint to Kai keeps its reviewed composition and
publishes the same SBOMs. The code is a port of roc-blueprint's
`blueprint-sbom`, under its UPL licence.

## Using it

Add the plugin to Kaifile.roc beside std, with the same settings:

```roc
app [kaifile] {
	pf: platform "<platform URL>",
	std: "<std URL>",
	sbom: "<sbom plugin URL>",
}

import pf.Kaifile
import std.Config
import std.Std
import sbom.Sbom

project : List(Config.Setting)
project = [
	Name("site"),
	# ...
]

kaifile = Kaifile.new([Std.plugin(project), Sbom.plugin(project)])
```

The plugin URL is the `sbom:` line in your kai's release notes: each
release after 0.0.11 publishes the sbom plugin bundled against its own
platform and std, as `sbom-<hash>.tar.zst`, and `plugins/sbom-release` in
its source records the URL. `examples/sbom` is a
small project with a reviewed composition.

## Commands

`kai sbom ACTION`, with files named by options and the rest after `--`:

| Action | What it does |
|---|---|
| `inputs [-- TARGET]` | Prints the input names a composition must dispose of for `TARGET` (`source`, the default, or a system), one per line. |
| `pins` | Prints the locked file sources and downloads as the format-2 lock report supplier SBOM fetchers read (`format`, `sources` by name with `provider`, `ref`, `rev`, `digest`, `digestKind`, `flatSha256` and `content_identity`, and `fetched` with `name`, `system`, `urls`, `sha256` and `content_identity`). |
| `inspect --composition FILE [--members FILE] [--output FILE] -- TARGET` | Checks the composition against the project for `TARGET` and writes the inventory to `--output`, or prints it. With `--members`, a `source` inventory must account for every member of the archive listing. |
| `bind --inventory FILE --subject FILE --context FILE --artifact FILE` | Writes `ARTIFACT.spdx.json` (SPDX 3.0.1), `ARTIFACT.cdx.json` (CycloneDX 1.7) and the manifest `ARTIFACT.sbom-manifest.json` beside the artifact. |
| `bind … --artifact FILE --output FILE [--spdx-2-3 \| --cyclonedx] [--manifest FILE]` | Writes one document to `--output`: SPDX 3.0.1, or SPDX 2.3 or CycloneDX 1.7 with a flag, and with `--manifest` the manifest of that one sidecar. |
| `check [--manifest FILE] [--inventory FILE] [--artifacts DIR] [-- DOCUMENT...]` | Checks each document, and each sidecar the manifest lists: valid in its format, one described subject, evidence that is the inventory's, one package graph across renderings, and the manifest's digests and sizes, which kai hashes again from the release file beside the manifest (or in `--artifacts`), the sidecars and the inventory. With `--artifacts`, each document's subject is also the file of its name in `DIR`, byte for byte. |
| `members [--output FILE] [--] ARCHIVE` | Lists the archive's regular members in archive order, each with its size and SHA-256, as the member listing `inspect --members` reads, to `--output` or stdout. An archive with a link, a device, an unsafe name or a member listed twice is refused. |

Each prints the paths it writes, as `blueprint-sbom` does. Every document
is rendered before any is written, so a refusal writes nothing. The
documents of a check are relative to the project's root, or absolute; the
options take paths relative to the directory kai runs in.

## Input names

Every input the project declares or locks needs a reviewed *disposition* in
the composition's `inputs`: the component it became, or why none. Kai names
them as roc-blueprint does, so a composition reviewed for a Blueprint
project fits the same project on Kai:

| Kaifile | Name |
|---|---|
| `FetchAll(NAME, …)`, or any download that is one URL and one SHA-256 on every system and that no environment puts on `PATH` | `source:NAME`, a file source (Blueprint's `SourceFile`) |
| Any other `Fetch`, `FetchAll` or `FetchLocked` file | `program:NAME:SYSTEM`, for `TARGET` alone unless it is `source` |
| A package tool, `SOURCE#NAME` (in `OnSystems`, on those systems only) | `tool:SOURCE#NAME` |
| The package sources tools use, overlays and flake inputs, by their Nix pins | `source:NAME` |
| A `RocPackages` bundle `…/HASH.tar.zst` | `roc-package:HASH` and `build-source:roc-HASH` |
| `Source(NAME, …)` | `build-source:NAME` |
| `CargoVendor(NAME, …)` | `cargo-vendor:NAME` |
| `Task(NAME, …)`, `Build(NAME, …)` | `task:NAME`, `build:NAME` |
| A member of the `--members` listing no component states by SHA-256 | `archive-member:NAME:SHA256` |

`kai sbom inputs` prints them. A component whose `origin` is `source:NAME`
or `program:NAME:SYSTEM` takes its identity, download and digest from the
pin: a file source is `urn:blueprint:source:NAME::sha256:HEX`, a program
`urn:blueprint:fetched:NAME:SYSTEM:HEX`. Each needs a supplier SBOM in the
composition's `imported_documents`, bound to the pinned bytes, or an
`unavailable_sboms` entry saying why there is none. Guix package sources
are not inventoried yet, and refused.

A download the lock should pin and does not fails with
`missing_direct_lock`, one pinned for another URL with `stale_lock`, a
missing Nix pin with `missing_lock`; `kai update` fixes each.

## Files

All are JSON, at most 1 MiB:

- **Composition**: `profile` (`blueprint-spdx-3.0-v2`, or `-v1`, read as
  v2), `components`, `relationships`, `coverage`, `inputs`,
  `imported_documents` and `unavailable_sboms`, as roc-blueprint's
  [SBOM guide](https://github.com/lukewilliamboswell/roc-blueprint/blob/main/docs/sbom.adoc)
  describes them.
- **Member listing**: `archive`, `sha256` and `members`, each `name`,
  `size` and `sha256`, in archive order: what `kai sbom members` writes,
  as `blueprint-sbom members` does for a `.tar.zst`.
- **Inventory**: what `inspect` writes; `bind` and `check` read it.
- **Subject**: `filename`, `version`, `target` and `url`, with the
  release file's `sha256` and, for a manifest, its `size` in bytes. `kind`,
  `producer`, `license`, `license_url`, `copyright` and `attribution` are
  optional.
- **Context**: `namespace` (an `https://` URI ending in
  `revision-REVISION`), `revision`, `created` (RFC 3339), `author`
  (`Person: …` or `Organization: …`) and `generator` (`Tool: NAME-VERSION`).
  The generator is the one name a document gives its tool; for Kai's,
  `Tool: kai-sbom-<kai version>`.

## Outside a project

`kai sbom` also runs in a directory with no Kaifile.roc, such as one holding
a downloaded release: kai then uses the sbom plugin of its own release, from
a Kaifile.roc it keeps in its cache, with its generated files there too. It
has no project, so `check`, `members` and `bind` are the actions that help;
paths, after `--` too, are relative to the directory kai runs in. To check a
release's sidecars against the release file beside them:

```sh
kai sbom check --manifest app.tar.zst.sbom-manifest.json
```

## Purity, and what a release workflow does itself

Plugins are pure: kai performs a plan's effects. `kai sbom` reads the files
it is given by having kai copy each into `.kai/generated/sbom/input` with
`cp` and read the copy back, and writes each output into
`.kai/generated/sbom/output` before copying it to its path, so
`kai --dry-run sbom …` shows every step. A release file and an archive's
members are hashed by kai itself (a plan's `Hash` step), never read by the
plugin. It needs `cp`, and `members` needs `sh` and a `tar` that reads the
archive (GNU tar with `zstd` for a `.tar.zst`, or bsdtar). So:

- **The subject's digest and size** come from the subject file, which the
  workflow writes after hashing the release file; `check` hashes the
  release file again and holds the manifest to it.
- **The member listing** of a source bundle comes from `kai sbom members`,
  which lists the archive with `tar`, unpacks it into
  `.kai/generated/sbom/members` and hashes each member.
- **Supplier SBOMs** are fetched by the workflow, as roc-automation's
  `fetch-dependency-sboms` does from `kai sbom pins`: it finds each
  supplier's sidecar beside the pinned URL and records it in
  `imported_documents`.

For a release workflow such as roc-automation's `sbom-sidecars`, each
`blueprint-sbom` step maps to one `kai sbom` step:

| roc-blueprint | Kai |
|---|---|
| `blueprint spec` and `Blueprint.lock`, passed to `inspect` | the Kaifile and `.kai/lock.json`, which kai reads itself |
| `blueprint lock show --json` | `kai sbom pins` |
| `blueprint-sbom members ARCHIVE OUT` | `kai sbom members --output OUT -- ARCHIVE` |
| `blueprint-sbom inspect SPEC LOCK COMPOSITION TARGET OUT [--members L]` | `kai sbom inspect --composition COMPOSITION --output OUT [--members L] -- TARGET` |
| `blueprint-sbom bind INVENTORY SUBJECT CONTEXT ARTIFACT` | `kai sbom bind --inventory INVENTORY --subject SUBJECT --context CONTEXT --artifact ARTIFACT` |
| `… ARTIFACT OUT --spdx-2.3` | `… --artifact ARTIFACT --output OUT --spdx-2-3` |
| `blueprint-sbom check --manifest M --inventory I --artifacts DIR DOC…` | `kai sbom check --manifest M --inventory I --artifacts DIR -- DOC…` |

## Identifiers that keep Blueprint's name

The documents are roc-blueprint's profile, and some of its identifiers say
so. They stay, because each is part of the published data that consumers,
checkers and other projects' imports match on, not a name of the tool:

- the profile `blueprint-spdx-3.0-v2`, in each document's evidence and in
  the manifest, which release checkers compare;
- the identities `urn:blueprint:source:…`, `urn:blueprint:fetched:…` and
  `urn:blueprint:archive-member:…` of locked inputs and archive members,
  which a project importing this SBOM binds to;
- the CycloneDX properties `blueprint:kind`, `blueprint:identity`,
  `blueprint:evidence` and the rest, which carry what CycloneDX has no
  field for and which `check` reads back.

Changing any of them would change every published SBOM and break the
documents other projects already import. The tool itself is named only by
the context's `generator`, so a release made with Kai names `kai-sbom`, and
its documents differ from roc-blueprint's in that name alone.

## Parity with `blueprint-sbom`

`plugins/sbom` tests this on weaver's 0.10.1 release, from weaver's Kaifile
on Kai, its lock, its reviewed composition and imports, and its bundle's
members: the inventory, the three sidecars and the manifest are its
published files byte for byte when the generator is `blueprint-sbom-0.11.0`,
and differ only in that name when it is `kai-sbom`. roc-blueprint's own
fixture cases (native, source import, the refusals of tampered imports)
give the same inventories and documents.
