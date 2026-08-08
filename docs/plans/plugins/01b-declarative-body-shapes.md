# Plan 01b: Parse declarative plugin body shapes

**Commit:** `feat: parse declarative plugin body shapes`  
**Budget:** 200–450 changed code/test lines  
**Depends on:** plan 01

## Goal

Parse and validate commands' declarative block-body schemas in shared pure
code before a plugin renderer runs.

## Changes

1. Extend the shared pure body module from plan 01 with parsing and validation
   for its object shapes, string values, and lists of strings.
2. Parse field syntax, quoted strings, lists, comments, and whitespace without
   trimming the source. Report duplicate fields, unknown fields, missing
   required fields, wrong value types, malformed strings, and malformed list
   syntax.
3. Make every diagnostic offset a zero-based UTF-8 byte offset relative to the
   selected block body. Do not scan top-level command or host blocks here.
4. Return generic validated configuration and provide safe string,
   string-list, and optional accessors for renderers.
5. Use the `RenderContext` configuration added in plan 01 while retaining its
   located raw body for later semantic diagnostics.
6. Make the standard shell and custom fixture registry renderers consume their
   already-declared `pkgs` and `message` fields through validated generic
   configuration. Keep callback adapters working until generic dispatch is
   adopted.
7. Put focused parsing, validation, offset, and accessor tests in the existing
   `xkai-bin/plugin-tests.roc` app root.
8. Add a sibling app test root for the custom fixture that exercises its
   declared schema and proves its registry renderer consumes validated
   configuration rather than reparsing the retained raw body. Do not add a
   package manifest to the custom plugin root.

## Files

- Modify `xkai-bin/Body.roc`.
- Modify `plugins/StdPlugin.roc`.
- Modify `examples/custom-plugin/CustomPlugin.roc`.
- Add `examples/custom-plugin/plugin-tests.roc`.
- Modify `xkai-bin/plugin-tests.roc`.

## Acceptance criteria

- Valid bodies preserve decoded string values and list order.
- Duplicate, unknown, missing, wrong-type, and malformed values fail with a
  body-relative byte offset.
- Comments and whitespace are accepted outside strings, including within
  lists, and `#` inside a string remains data.
- Accessors return errors rather than trapping on a missing or mismatched key.
- Standard and custom registry renderers contain no handwritten body parsing.
- The custom fixture's schema and validated-config renderer have focused tests
  in an executable app root.
- Existing callback integration behavior remains unchanged.
- `zig build ci` passes.

## Not included

- Universal `Kaifile` scanning or host/backend block selection.
- Numbers, booleans, nested objects, arbitrary lists, defaults, or field-name
  aliases.
- Generic registry dispatch.

## Risks

Keep this a direct parser over UTF-8 bytes rather than a parser framework.
The generic value model is intentionally small; add value kinds only when a
real plugin requires them.
