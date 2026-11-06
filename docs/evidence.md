# Build evidence: tools and inputs

A step inside a build, such as one writing an SBOM or a provenance file,
needs to name exactly what produced the artifact. Every Nix build gets:

- `$KAI_TOOLS`, a directory with one symbolic link per tool of the build's
  environment, named as the Kaifile writes the tool (`cowsay`,
  `unstable#roc`, `jq#jq`), pointing at the tool's store path. The
  environment's `RustToolchain`, if any, is `rust-toolchain`.
- `$KAI_INPUTS/.kai-inputs.json`, a record of the build's inputs, which no
  input name can clash with.

No `Env` can set `KAI_TOOLS`. Guix builds get neither yet.

The build's closure holds its tools already, so `$KAI_TOOLS` adds nothing to
an artifact unless the artifact names a store path: Nix keeps every path
whose hash an output contains. Copying `readlink "$KAI_TOOLS/cowsay"` into
the artifact keeps cowsay in its closure; keeping only the name after the
hash, such as `cowsay-3.8.4`, does not. The record holds no store paths, so
an artifact can copy it whole.
[`kai build NAME --plan`](build-plan.md) prints the same records, and each
need's derivation and output path, without building.

## The record

`schema_version` is 1. A new field keeps the version; a field that changes
meaning or goes away bumps it. `inputs` lists the build's `Inputs` in
order, then its `Needs`, each with every field below, `null` where it does
not apply. Nix writes keys in sorted order.

| Field | Meaning |
|---|---|
| `name` | The name in `Inputs` or `Needs`, as [`kai spec`](spec.md) lists the build's; a source's is also its [`kai lock`](lock.md) name. |
| `kind` | `source`, `fetch`, `cargo_vendor` or `artifact` (a `Needs` build). |
| `url` | A source's reference as declared, or the URL of a fetch's file for the system the build runs on. |
| `revision` | A source's locked commit, Nix's `rev`. |
| `hash` | As `kai lock` gives it: `algorithm` (`sha256`), `of`, `encoding` and `value`. A source has its NAR hash (`nar`, `sri`), a fetch its file's SHA-256 (`file`, `sri`), and a cargo vendor the SHA-256 of its Cargo.lock (`file`, `hex`), whose checksums pin each crate. An artifact has none. |

## Example

[examples/source-build](../examples/source-build)'s `kai build evidence`
keeps the record, which, formatted, is

```json
{
  "inputs": [
    {
      "hash": {
        "algorithm": "sha256",
        "encoding": "sri",
        "of": "nar",
        "value": "sha256-…"
      },
      "kind": "source",
      "name": "cows",
      "revision": "…",
      "url": "github:tnalpgge/rank-amateur-cowsay/cowsay-3.04"
    }
  ],
  "schema_version": 1
}
```
