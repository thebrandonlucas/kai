# Blueprint

Blueprint is the smallest protocol a determinate system can implement so that
a frontend such as `kai` can drive it. A **backend** is an executable. A
frontend runs it with a command and reads its result; it never links it or
knows how it works.

Nix, Guix and blu (this directory's Roc implementation) are three backends.

## Invariants

A backend is determinate when these hold. The commands only exercise them.

| # | Invariant | Meaning |
|---|---|---|
| 1 | Addressed outputs | An output is named by a hash and is never mutated after it is stored. |
| 2 | Hermetic builds | A build sees only its declared inputs. Only fixed-output fetches reach the network. |
| 3 | Closures | Everything an output references can be computed. |
| 4 | Atomic generations | A profile points at one output. Switching and rolling back move that pointer atomically. |
| 5 | Roots | Nothing reachable from a generation is ever collected. |

## Invocation

```
BACKEND COMMAND [ARG...]
```

- **stdout** carries the result, one record per line. **stderr** is for people.
- **Exit status:** 0 success, 1 failure, 2 usage error, 3 unsupported (the
  command, input format or target is outside what the backend can do).
- **INPUT** is `FORMAT:PATH`. Every backend accepts `kai-ir`, the Kaifile IR
  that `kai ir` prints. A backend may also accept one native format.
- **Relative paths** resolve against the working directory. For `kai-ir`,
  the working directory is the project root.

## Commands

Commands come in tiers, and a backend implements whole tiers.

| Tier | Command | Result on stdout |
|---|---|---|
| core | `capabilities` | `blueprint 0`, `tiers T...`, `inputs F...` |
| core | `build INPUT TARGET` | the output path |
| env | `shell INPUT TARGET [-- ARGV...]` | none; runs ARGV (default `sh`) in the environment and exits with its status |
| system | `switch INPUT TARGET` | `N PATH`, the new current generation |
| system | `rollback` | `N PATH`, the generation now current |
| system | `generations` | `N PATH` per generation, the current one suffixed ` current` |
| store | `gc` | each deleted path |

For `kai-ir` input, `build` takes a build name, while `shell` and `switch`
take an environment name. The frontend resolves Kaifile shells and tasks to
their environment itself.

## Backends

| Blueprint | Nix | Guix | blu |
|---|---|---|---|
| native input | `nix:` flake ref | `guix:` manifest `.scm` | `blu:` directory of `.blu` recipes |
| tiers | core env system store | core env system store | core env system store |
| `build` | `nix build` | `guix build` | [`Store.realise!`](blu/Store.roc) |
| `shell` | `nix shell` / `nix develop` | `guix shell --pure` | [`main.roc`](blu/main.roc) `shell!` |
| `switch` | `nix profile install` | `guix package -m` | [`Store.switch!`](blu/Store.roc) |
| `rollback` | `nix profile rollback` | `guix package --roll-back` | [`Store.rollback!`](blu/Store.roc) |
| `generations` | `nix profile history` | `guix package -l` | [`Store.generations!`](blu/Store.roc) |
| `gc` | `nix store gc` | `guix gc` | [`Store.gc!`](blu/Store.roc) |
| 1 addressed | `/nix/store`, input-addressed | `/gnu/store`, input-addressed | `$BLU_HOME/store`, content-addressed |
| 2 hermetic | build sandbox (daemon) | `guix-daemon` chroot | `bwrap`, rootless, no daemon |
| 3 closures | reference scanning | reference scanning | declared inputs (`db/refs`) |
| 4 generations | profile symlinks | profile symlinks | profile symlinks |
| 5 roots | `/nix/var/nix/gcroots` | `/var/guix/gcroots` | `$BLU_HOME/profiles` |
| in `kai` | [`NixBackend`](../kaifile/nix/NixBackend.roc) (in process) | [`GuixBackend`](../kaifile/guix/GuixBackend.roc) (in process, shell only) | [`BluBackend`](../kaifile/blu/BluBackend.roc) (over Blueprint) |

## blu

`blu` is the reference backend, written in Roc. Its native input is a
directory of recipes, one `NAME.blu` per recipe (see [pkgs](blu/pkgs)):

```
((name "hello")
	(inputs ("base"))
	(build (Run ("sh" "-c" "..."))))
```

- A recipe's `build` is one of these:
  - `(Fetch ((url U) (sha256 H) (path P)))` downloads U to `$out/P`, checks it against H, and makes it executable.
  - `(Run ARGV)` runs ARGV in a `bwrap` sandbox with no network. Each input is
    exposed as `$NAME`, their `bin` directories are on `PATH`, and the output
    goes in `$out`.
  - `Union` joins the inputs' `bin` directories.
- **Content addressing:** an output is stored at `store/HASH-NAME`, where HASH is
  the sha256 of its normalized tar stream. `db/realisations/KEY` caches the
  output for a recipe, where KEY is the hash of the recipe with its inputs
  resolved.
- **No self-references:** `$out` is `/out` inside the sandbox, so an output
  must never embed its own path.
- **kai-ir:** tools resolve to recipes in `$BLU_PKGS`. An environment becomes
  a `Union`, and a Kaifile build runs inside a snapshot of the project.
- **Host requirements:** `bwrap`, `curl`, `tar`, `sha256sum` and coreutils.
  Only x86_64-linux is supported.
- **Locations:** `BLU_HOME` defaults to `~/.local/share/blu`. There is one
  profile, `profiles/current`, so `profiles/current/bin` can go on `PATH`.
