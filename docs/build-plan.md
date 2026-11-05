# `kai build NAME --plan` and `--rebuild`

## The plan

`kai build NAME --plan` prints what a build is, as one line of JSON, for
tools such as SBOM generators and release checks, without building it. It
readies the build as `kai build` does: it checks the lock and the build's
local sources, snapshots the project and writes the generated flake. Then,
instead of building, it has Nix evaluate the build, which copies the
snapshot into the store but builds nothing. With `--json`, the document is
the `message` of a `result` event.

`schema_version` is 1. A new field keeps the version; a field that changes
meaning or goes away bumps it. Nix writes keys in sorted order. Only Nix
builds have a plan; Guix refuses `--plan`.

| Field | Meaning |
|---|---|
| `schema_version` | 1. |
| `backend` | `nix`. |
| `name`, `environment`, `output` | The build's name, its environment's name and its `Output`, as [`kai spec`](spec.md) lists them. |
| `system` | The system the build runs on, such as `x86_64-linux`. |
| `files` | The build's `Files`, or `null` for every file. |
| `inputs` | The records of the build's inputs and needs that the build finds in `$KAI_INPUTS/.kai-inputs.json`, with the same fields; see [evidence.md](evidence.md). |
| `needs` | Each build in `Needs`: `name`, `derivation` and `output_path`, the need's identity that the record leaves `null`. |
| `snapshot` | The store path of the project's snapshot as the build reads it. Nix names it by the SHA-256 of its contents (a NAR serialization) and the name `kai-project`, so the same files give the same path. |
| `derivation` | The build's Nix derivation path. |
| `output_path` | The store path the build's output will have. |

The derivation also includes the mount and network namespace identities
kai runs in, which builds check their sandbox against, so the derivation
and output paths stay the same across runs on one machine, but may differ
where kai runs in another namespace, such as in a container.

For [examples/build](../examples/build), `kai build wisecow --plan | jq`
prints

```json
{
  "backend": "nix",
  "derivation": "/nix/store/…-kai-wisecow.drv",
  "environment": "cow",
  "files": [],
  "inputs": [],
  "name": "wisecow",
  "needs": [],
  "output": "wisecow",
  "output_path": "/nix/store/…-kai-wisecow",
  "schema_version": 1,
  "snapshot": "/nix/store/…-kai-project",
  "system": "x86_64-linux"
}
```

## Rebuilding

`kai build NAME --rebuild` builds again and fails if the output differs from
the one already in the store, as Nix's `nix build --rebuild` does: a build
that passes is reproducible on this machine. The output must already be in
the store, from an earlier `kai build NAME`, or Nix refuses to check it.
`--plan` and `--rebuild` do not combine, and Guix refuses `--rebuild`.
