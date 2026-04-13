# Build feature description flag

> created: 2026-04-13

> [!warning] Archived
> This plan has been archived and is kept for reference only. It does not
> reflect active work.

## Problem

The build currently pulls the jj change description (`description.first_line()`)
automatically and bakes it into every binary's `--version` output. This is
fragile -- the description might be empty, stale, or unrelated to the release.

## Goal

Remove the automatic jj description capture. Replace it with a required
`-Ddescription="..."` build option that must be passed explicitly for a release
build. Dev builds should still work without it (using a sensible default like
`"dev"`).

## Current state

### Where description is gathered

- `src/build/BuildConfig.zig:38-46` -- runs
  `jj log --no-graph -r @ -T "description.first_line()"` at build time.
- `src/build/BuildConfig.zig:13` -- `description` field on the struct.
- `src/build/BuildConfig.zig:64` -- trimmed and stored in init return.
- `src/build/BuildConfig.zig:74` -- passed into the `build_option` module.

### Where description is consumed

- `src/exec/trash.zig:89` -- `--version` output.
- `src/exec/copy.zig:80` -- `--version` output.
- `src/exec/move.zig:72` -- `--help` version footer.
- `src/exec/move.zig:82` -- `--version` output.
- `src/exec/repo-open.zig:78` -- `--version` output.

### Inconsistency note

`move.zig` includes `description` in both `--help` and `--version` output.
The other executables only include it in `--version`. The `--help` output for
`trash.zig` does not include description at all. This should be normalized as
part of this work.

## Plan

### 1. Add `-Ddescription` build option to `BuildConfig.init`

In `src/build/BuildConfig.zig`:

- Remove the `jj log ... description.first_line()` command (lines 38-46).
- Add a user build option via `b.option([]const u8, "desc", "...")`.
- Default to `"dev"` for debug builds. Fail with a compile error for release
  builds (`ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) when `-Ddesc` is not
  provided.
- Keep the `description` field and the rest of the flow unchanged.

```zig
const maybe_description = b.option(
    []const u8,
    "desc",
    "Short feature description for the build (required for release).",
);

const is_release = optimize != .Debug;
if (is_release and maybe_description == null) {
    @panic("release builds require -Ddesc=\"...\"");
}

const description = maybe_description orelse "dev";
```

### 2. Normalize version output across executables

Pick one format and apply it to all four executables for both `--help` and
`--version`. Proposed format:

**`--version`:**
```
<name> version: (<date>) <change_id[0..8]> <commit_id[0..8]> -- '<description>'
```

**`--help` version footer:**
```
  Version:
    <version> <change_id[0..8]> <commit_id[0..8]> (<date>) '<description>'
```

Files to update:
- `src/exec/trash.zig` -- add `description` to `--help` footer.
- `src/exec/move.zig` -- already has both, use as reference.
- `src/exec/copy.zig` -- add `description` to `--help` footer.
- `src/exec/repo-open.zig` -- add `description` to `--help` footer.

### 3. Update TODO

Remove the `-Djj_ref` TODO item from `plan/TODO.md` since this work supersedes
it.

### 4. Test

- `zig build` (debug, no `-Ddesc`) -- should compile, `--version` shows `dev`.
- `zig build -Doptimize=ReleaseSafe` (no `-Ddesc`) -- should fail with a clear error.
- `zig build -Doptimize=ReleaseSafe -Ddesc="Add trash undo"` -- should compile,
  `--version` shows the string.
- Run existing integration tests to make sure nothing else broke.

## Decisions

- Flag name: `-Ddesc`.
- Release builds (`ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) fail if
  `-Ddesc` is not provided. Debug builds default to `"dev"`.
