# `kai lock`: the lock as JSON

`kai lock` prints every input `.kai/lock.json` pins as one line of JSON, for
tools such as SBOM generators and release checks, so they need not read the
lock, whose layout may change. It reads only the lock, so it needs no
backend or network, and it changes nothing. It reports what the lock holds
even when `Kaifile.roc` has changed since `kai update`; `kai shell`, `run`,
`build` and `workflow` say when the lock is stale. With no lock it fails
with `missing_lock`, and with a malformed one with `invalid_lock`. With
`--json`, the document is the `message` of a `result` event.

`schema_version` is 1. A new field keeps the version; a field that changes
meaning or goes away bumps it.

## Fields

`inputs` lists every pinned input std's sections hold: the `nix` section's,
then `direct`'s. Each has every field below, `null` where it does not
apply. Sections other plugins own, such as the guix plugin's `guix`, are
left out.

| Field | Meaning |
|---|---|
| `section` | The lock section that pins it: `nix` or `direct`. |
| `kind` | `nix`: `package_source`, `overlay`, `flake_input`, `source` or `transitive`. `direct`: `file`. |
| `name` | The identifier [`kai spec`](spec.md) uses: package sources, overlays, flake inputs and sources by `name`, and downloaded files by `key` (`<fetch>/<system>`). A `transitive` input is named by its path from a root input, such as `roc/nixpkgs`. |
| `url` | The reference as declared: a Nix flake reference (for `transitive`, the one the depending flake names), or a downloaded file's URL. |
| `revision` | The locked commit: Nix's `rev` for Git-based inputs. |
| `hash` | `algorithm` (`sha256`), `of` (`nar` for a NAR serialization of a tree, `file` for a file's bytes), `encoding` (`sri` as in `sha256-…`, or `hex`) and `value`, as the section records it: Nix inputs by NAR hash, downloaded files by SHA-256. |
| `size` | A downloaded file's size in bytes. |
| `system` | A downloaded file's system. |
| `locked` | A Nix input's `locked` attributes from Nix's `flake.lock`, as Nix defines them (`type`, `owner`, `repo`, `rev`, `url`, `narHash`, `lastModified`, …). |

Nix root inputs keep their declaration order and are followed by the
inputs they pull in, each node once; an input that `follows` another is
the node it follows. Cargo.lock, not the lock, pins a `CargoVendor`'s
crates, and a `Fetch` that gives its sha256 needs no lock entry, so neither
appears.

## Example

For a project using `default` packages and a `FetchLocked("jq", …)` file,
after `kai update`, `kai lock | jq` prints

```json
{
  "schema_version": 1,
  "inputs": [
    {
      "section": "nix",
      "kind": "package_source",
      "name": "default",
      "url": "github:NixOS/nixpkgs/nixos-unstable",
      "revision": "4975466d324710c576dc11ad614684e6bd8cad8e",
      "hash": {
        "algorithm": "sha256",
        "of": "nar",
        "encoding": "sri",
        "value": "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU="
      },
      "size": null,
      "system": null,
      "locked": {
        "lastModified": 1790185690,
        "narHash": "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=",
        "owner": "NixOS",
        "repo": "nixpkgs",
        "rev": "4975466d324710c576dc11ad614684e6bd8cad8e",
        "type": "github"
      }
    },
    {
      "section": "direct",
      "kind": "file",
      "name": "jq/x86_64-linux",
      "url": "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64",
      "revision": null,
      "hash": {
        "algorithm": "sha256",
        "of": "file",
        "encoding": "hex",
        "value": "5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
      },
      "size": 2319424,
      "system": "x86_64-linux",
      "locked": null
    }
  ]
}
```
