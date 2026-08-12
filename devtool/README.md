Goal here is to eventually build our build system in `roc`! Allowing us to have one tool that can just do all the things. Right now these `zig build build-release` and `zig build release -- "<release-name> x.x.x` are written in `roc` and invoked via `zig`.

Basically the idea is that we have a list of "monotonically growing checks" that define what our codebase is, and that this should (eventually):

A) All be in the language you're already using for the project, as `bash`/`python` are finnicky.
B) Let CI call the build system which can run locally (don't duplicate yml workflow logic). CI _should_ be locally runnable.
C) The process of cloning -> binary should be only one command, regardless of device. (Nix + build system should handle it)
D) There's a set of things your project has to do at intervals (build, sign, tag, upload, validate, and generate a changelog for a new release). One build system should be a set of commands which handles all these.

Comes from [matklad's "Basic Things"](https://matklad.github.io/2024/03/22/basic-things.html#Build-CI).
