# Plan 03: Stage custom plugin source trees

**Commit:** `feat: build plugins from modular source trees`  
**Budget:** 300–500 changed code/test lines  
**Depends on:** plans 01–02

## Goal

Allow `xkai build path/to/Plugin.roc` to compile plugin component modules from
`commands/`, `backends/`, and `implementations/` while retaining one-file
plugin support during migration.

## Changes

1. Treat the supplied top-level `.roc` file's parent as the plugin root.
2. Discover `.roc` files under the three recognized component directories,
   preserving relative paths in the temporary stage.
3. Generate the staged Roc package exposure/import wiring needed by the
   discovered modules. Do not require one file per component; the top-level
   module may still define any or all lists itself.
4. Reject before invoking Roc:
   - a non-`.roc` top-level path;
   - symlinks or relative paths escaping the plugin root;
   - duplicate staged module names;
   - user-supplied package manifests that conflict with generated manifests;
   - unreadable files.
5. Keep the current single-file custom plugin integration test.
6. Add a minimal modular fixture whose top-level `Plugin.roc` imports one
   command, backend, and implementation module. At this stage it only needs to
   build into a `kai` binary; runtime dispatch arrives in plan 06.
7. Verify temporary trees are removed after successful and failed builds and
   no source is copied into `.kai`.

## Files

- Modify `xkai-bin/main.roc`.
- Modify `scripts/test-xkai-projects.sh`.
- Add `examples/modular-plugin/Plugin.roc`.
- Add `examples/modular-plugin/commands/Write.roc`.
- Add `examples/modular-plugin/backends/Local.roc`.
- Add `examples/modular-plugin/implementations/WriteLocal.roc`.

## Acceptance criteria

- Existing standalone plugins still compile.
- A top-level plugin importing all three component directories compiles.
- Two plugin trees passed to one build remain isolated even if component
  filenames match.
- Failed staging/builds leave neither `kai` nor an `xkai-*` temporary tree.
- `zig build ci` passes.

## Not included

- Structural validation beyond normal Roc type checking.
- Executing registry-only plugin commands.

## Risks

Directory iteration and canonicalization depend on the pinned `basic-cli` API.
Do not shell out to `find` from xkai. Reject symlinks instead of attempting to
prove that an arbitrary link target is safe.
