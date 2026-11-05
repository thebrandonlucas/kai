# `kai spec`: the project as JSON

`kai spec` prints what `Kaifile.roc` declares as one line of JSON, for tools
such as SBOM generators and release checks. It reads only `Kaifile.roc`, so
it needs no lock, backend or network, and it changes nothing. With `--json`,
the document is the `message` of a `result` event.

`schema_version` is 1. A new field keeps the version; a field that changes
meaning or goes away bumps it. Lists keep declaration order.

## Fields

| Field | Meaning |
|---|---|
| `schema_version` | 1. |
| `name`, `systems`, `build_root` | `Name`, `Systems` and `BuildRoot` (`""` for the project's directory). |
| `package_sources` | `Packages`, with the implicit `default`: `name`, `provider` (`auto`, `nix` or `guix`) and `ref` (the flake ref or Guix specification, `null` for `auto`). |
| `guix_channels` | `GuixChannel`: `name`, `url`, `branch`, `introduction_commit`, `introduction_signer`. |
| `overlays` | `Overlay`: `name`, `ref` and `follows` (`input`, `source`). |
| `flake_inputs` | Other flake inputs: `name`, `ref`. |
| `sources` | `Source`: `name`, `ref`. |
| `fetches` | `Fetch`, `FetchAll` (one file per available system) and `FetchLocked`: `name`, `pinned_by` (`hash` when the Kaifile gives each sha256, `lock` for `FetchLocked`), `unavailable_on`, and `files`: `key` (`<fetch>/<system>`), `system`, `url`, `mirrors`, `hash` (`null` when the lock pins it, else `algorithm` `sha256`, `of` `file`, `encoding` `sri` and `value`) and `archive_path` (the program inside an archive, else `null`). |
| `cargo_vendors` | `CargoVendor`: `name`. |
| `environments` | Each environment with what it extends already merged in: `name`, `tools`, `overlays`, `env`, `package_env` (`name`, `kind`: `library_path`, `bin_path` or `package_path`, `tools`), `pure`, `aliases` (`name`, `tool`, `binary`), `rust_toolchain` (`null`, or `toml`, `components`, `targets`) and `on_systems` (`systems`, `tools`, `env`). |
| `shells` | `name`, `description`, `environment`. |
| `tasks` | `name`, `description`, `environment`, `run`, `dir`, `env`, `secrets`, `optional_environment_variables`, `needs`. |
| `builds` | `name`, `description`, `environment`, `run`, `output`, `inputs` (`name`, `kind`: `source`, `fetch` or `cargo_vendor`), `needs`, `files` (`null` for every file), `env`, `revision`, `default`. |
| `workflows` | `name`, `description`, `steps`: `action` (`run`, `build` or `workflow`, as in `step_started` events), `name`, `args`, `may_fail`. |

A tool has a `name` and says where it comes from in `from`:

- `package`: `source` is a `package_sources` name.
- `download`: `fetch` is a `fetches` name, and `name` is the program it puts
  on `PATH`.
- `expected`: a program the machine must have (`Expect`).

`env` lists are `name` and `value` pairs. Secrets are names only, never
values.

Names are identifiers that other reports share: package sources, overlays,
flake inputs and sources by `name`, Guix channels by `name`, and fetched
files by `key`, as `.kai/lock.json` pins them.

## Example

For

```roc
kaifile = Std.kaifile([
	Name("hello"),
	Systems(["x86_64-linux"]),
	FetchLocked("tool", [{ system: "x86_64-linux", url: "https://example.com/tool", mirrors: [], program: File }]),
	Environment("dev", [Tools(["cowsay", "tool#tool"]), Expect(["git"])]),
	Shell("default", [Use("dev")]),
])
```

`kai spec | jq` prints

```json
{
  "schema_version": 1,
  "name": "hello",
  "systems": ["x86_64-linux"],
  "build_root": "",
  "package_sources": [{ "name": "default", "provider": "auto", "ref": null }],
  "guix_channels": [],
  "overlays": [],
  "flake_inputs": [],
  "sources": [],
  "fetches": [
    {
      "name": "tool",
      "pinned_by": "lock",
      "files": [
        {
          "key": "tool/x86_64-linux",
          "system": "x86_64-linux",
          "url": "https://example.com/tool",
          "mirrors": [],
          "hash": null,
          "archive_path": null
        }
      ],
      "unavailable_on": []
    },
    {
      "name": "jq",
      "pinned_by": "hash",
      "files": [
        {
          "key": "jq/x86_64-linux",
          "system": "x86_64-linux",
          "url": "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64",
          "mirrors": [],
          "hash": {
            "algorithm": "sha256",
            "of": "file",
            "encoding": "sri",
            "value": "sha256-WULJsJNOUQ7mHrPjAnPxs/4lkN+TkzqT18WLgdGcj/U="
          },
          "archive_path": null
        }
      ],
      "unavailable_on": []
    }
  ],
  "cargo_vendors": [],
  "environments": [
    {
      "name": "dev",
      "tools": [
        { "name": "cowsay", "from": "package", "source": "default" },
        { "name": "tool", "from": "download", "fetch": "tool" },
        { "name": "git", "from": "expected" }
      ],
      "overlays": [],
      "env": [],
      "package_env": [],
      "pure": false,
      "aliases": [],
      "rust_toolchain": null,
      "on_systems": []
    }
  ],
  "shells": [{ "name": "default", "description": "", "environment": "dev" }],
  "tasks": [],
  "builds": [],
  "workflows": []
}
```
