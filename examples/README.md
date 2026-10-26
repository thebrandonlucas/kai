# Examples

Each example here is a small Kai project demonstrating one feature, used for E2E integration tests. `<kai>/devtool/Tidy.roc` holds an invariant that each Kai command will be exercised at least once here, so that we're regularly running real-world integrations alongside each command's unit tests.

The suite is run via `zig build e2e-examples`.

The layout for each example is:

```
Setup in each example/<example> dir is:
- example
    | commands          input command args to kai e.g. `update`, `run` etc.
    | Kaifile.roc       describes what to run given the above commands
    | stdout            expected stdout given the run for validation
```

Examples run using `wisecow`, a custom program which is a combination of the [`fortune`]() and [`cowsay`]() programs to demonstrate Kai's ability to create environments with programs and stitch them together in interesting and useful ways.

| Example | Shows | Try |
|---|---|---|
| [shell](shell) | An environment and a shell | `kai shell` |
| [task](task) | Tasks, and arguments after `--` | `kai run moo` |
| [environment](environment) | Reusable environments shared by shells and tasks | `kai shell pokemon` |
| [extend](extend) | One environment building on another | `kai run wisdom` |
| [env](env) | Environment variables, and a task overriding its `Environment`'s | `kai run shout` |
| [build](build) | A sandboxed build and its output | `kai build wisecow` |
| [needs](needs) | A build reading another build's artifact | `kai build loud` |
| [source-build](source-build) | A build reading a locked source | `kai build moofasa` |
| [path-source](path-source) | A build reading a locked project directory | `kai build kai` |
| [workflow](workflow) | Tasks, builds and workflows run in order | `kai workflow encore` |
| [packages](packages) | Package sources, a pinned release and flake inputs | `kai shell` |
| [raw](raw) | Passing Nix-specific data through with `Raw` | `kai shell` |
| [overlay](overlay) | An overlay adding a package, seen only where selected | `kai run moo` |
| [modules](modules) | Settings shared through an ordinary Roc module | `kai run moo` |
| [guix](guix) | Packages from a Guix channel beside the default source | `kai shell guix` |
| [agenix](agenix) | A tool from another flake's overlay, encrypting and decrypting a secret | `kai run round-trip` |
| [plugins/deploy](plugins/deploy) | A third-party plugin adding `kai deploy` | see [plugin.md](../docs/plugin.md) |

Run `kai update` first in each: it locks the packages the commands use.

Shells and tasks run on your machine with your files and network; builds run
sandboxed with only what they declare. See
[Tasks and builds](../README.md#tasks-and-builds).
