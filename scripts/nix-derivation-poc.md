# Persisted Nix derivation proof of concept

This POC evaluates one Nix installable once, then stores the resulting Nix
store graph in a Kai-owned directory. Later realization receives no Nix
installable or source expression.

```sh
scripts/import-nix-derivation.sh nixpkgs#hello .kai/hello.graph
scripts/realize-nix-derivation.sh .kai/hello.graph
```

The import command passes the installable only to
`nix path-info --derivation`. It then uses the returned `.drv` path to write:

- `format`: artifact format marker
- `root.drv`: the explicit realization root
- `derivations.json`: raw `nix derivation show --recursive` JSON
- `store.export`: `nix-store --export` of the root derivation closure

Realization checks/imports `store.export`, then runs only
`nix-store --realise` on `root.drv`. It never invokes `nix` or reads the
original flake/expression. Run the automated transfer test with:

```sh
zig build test
# Or directly:
scripts/test-nix-derivation-poc.sh
```

The test deletes the source flake, poisons the `nix` executable, disables and
verifies the effective substituter list, imports into an empty isolated store,
and realizes the persisted root.

## Trust and code provenance

Treat the artifact as executable input. Its persisted derivations select the
builders, arguments, environment, and input store paths that Nix will use;
realization executes that builder code under the receiving store's Nix daemon
and sandbox configuration. That code is whatever the installable resolved to
when the artifact was imported. The artifact does not retain the original
installable or attest that relationship.

The export stream preserves Nix's store-path/content integrity checks, but it
is unsigned and does not authenticate who produced it. Only realize artifacts
from a trusted producer, or authenticate them separately in transit and at
rest. The format marker, root path, and inspection JSON are not signatures.
Import into an empty multi-user store may require a trusted Nix user or an
appropriate signing/trust setup.

## Caveats

- Realizing in the original store skips import while the root remains valid.
- Store paths bind the artifact to a compatible Nix store directory, system,
  and builder environment. This is a boundary experiment, not a portable
  package format.
- The realized output is not registered as a GC root. The artifact can restore
  the derivation/input graph, but users must root outputs they want to retain.
- `derivations.json` is preserved for inspection; realization relies on Nix's
  canonical store export rather than reconstructing `.drv` files from JSON.
