Currently, in stdplugin we group everything like:

- the targets
- the parsing logic (?)
- the command specification
- the command backend impelmentation and side effects
- the rendered output

This means everything is coupled within that one plugin file which xkai build reads to compile into `kai`. but this means that every new plugin builder must build their own everything, the whole shape, from scratch. It should be more like this:

- `Plugin.roc` should be shaped like:
    - Top-level `Plugin.roc`, with subfolders:
        - `commands`
        - `backends`
        - `implementations`
    Then for each subfolder you import each into the `Plugin.roc` like so:
        - `List(Command)`: The generic command shape
        - `List(Backend)`: The possible backends (nix/guix/custom)
        - `List(Implementation)`: The (command, backend) impl combo
           includes a required render fn (for pure string(s) to render)
           and actions (side effects like exec and writing files) to do
- `StdPlugin.roc` then for example is:
    - `commands/shell.roc` (just the generic shell command). if we wanted we could have 
      single `commands.roc` file that had all of them, but we should give options to allow plugin dev to split it up.
    - `backends/nix.roc, backends/guix.roc` just the backend definitions. this is basically a list of the
      programs that are required to be installed on the system for the plugin to work. `xkai build` should be able to build in logic into the final `kai` binary to check whether these things are installed at runtime, and throw an error if not. We could even add in an optional command set hardcoded into the `nix.roc` backend file which would execute if `kai` finds that a user does not have the required programs installed. For example for the stdplugin if a user does not have guix we could say: "You appear to not have nix installed, would you like me to download it?", and then we use whatever OS-appropriate way there is to download `determinatenix`. This of course would be defined as one of the possible side-effect actions to be performed.
    - `impl/shell-nix.roc, impl/shell-guix.roc` the connective tissue that defines the concrete things that `Command` should do when given a `Backend`. There is both pure and effect free parts such as the strings to render and the actual "data" passing around. These are what we test to keep tests fast and effect/dep free, and there is effectful parts which are defined in the actions like we do it now.
    - `Plugin.roc`: for `StdPlugin.roc` would look something like:
        
        ```
       commands: [shell],
       backends: [nix, guix],
       implementations: [shell-nix, shell-guix]
        ```

Then `xkai build` would take these and build all these requirements into `kai` binary. And of course different plugins can define these three things above however they want, so long as they have them. The validations should be:
- TODO: modify the concept of a backend thus:
    - `Backend: { DeterminateSystem: <nix/guix/custom>, List(Package) }`. Anywhere in the doc I refer to backend assume I mean this.
    - In the `StdPlugin.roc` file, Validate that at least 1 of each exists (command, backend, implmenetation), and that the 


### Plugin internal validations. These are tests the plugin writer writes

- validate that all expected rendered data as data in/data out (i.e. string to be written to `flake.nix` matches expected outputs. For `shell` command, try with 1 package, 2 packages, 0 packages (should be an error?))
- validate that the `config.kai` which would result from this plugin is parseable in it's various configurations. for example is the following parseable:

```kai
shell {
  pkgs: [""]
}
```



### `xkai build` -> `kai` compile time validations. These are essentially validations that the plugin was written correctly.

- validate that:
    - for every `Implementation` there is a corresponding `backend` and `command`
    - every `backend` and `command` is used by at least one implementation (no danglers)

### `kai` runtime validations:
- In this system, the runtime validation is we can allow `kai` to check if the requirements (maybe we should 
      call them programs?) are available at runtime _within the selected package manager_! That last part is important. If some program is required by `kai` at runtime, I want `kai` to be able to determine if that program is installed not merely on the device (since it could have come from anywhere and is thus a source of impurity) but if that program is installed on device having come _from_ the `DeterminateSystem` that the implementation is using.
      fallback command if not (if it was written into the program).

- `config.kai` has an entry for every command which has a required corresponding `config.kai` `source` item. we should probably allow the plugin writer to make these required or optional.

- When parsing `config.kai` fails, it should not fail generically but point to the line/col which caused the failure, and try to explain what the actual problem is. This could be done relatively generically so as not to be required to be thought about by the plugin writer to an extent. There should be a split between builtin keywords (`on`, `linux`, `macos` etc.) for example, and syntax rules for these can just be builtin to all versions of `kai` since they are universal. And top-level syntax on whether a required keyword is missing or not can be thrown by `kai` relatively generically because it knows after `xkai build` compile time which commands are available/required/not. But syntax rules for plugins such as inner keywords must be done at `xkai build` compile time within the plugin itself and is therefore on the plugin writer. If a plugin writer forgets to write a proper test, and `kai` catches it at runtime when parsing, `kai` should still be able to at least point to which command failed to parse and tell the user that it's a bug in the plugin.

- When a specified `Package` is not available in the `DeterminateSystem`'s default package manager, it should fail with an error "I couldn't find <package> in <`DeterminateSystem` (e.g.) `nix`>'s <package source (e.g.) `nixpkgs`>. Did you mean <list of a couple close candidates based on standard algorithm for matching string closeness in cli tools>

## Plan

Generate plans based on the above under docs/. plans should come in small enough committable chunks to implement features progressively on our path to completing this spec. Each of these should be self-contained, reasonably reviewable (preferably 500 lines or under), and push us toward completing the spec. Each commit should pass CI, it is only ok to modify `build.zig` if you are doing it for adding new tests or fixing regressions.
