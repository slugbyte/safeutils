# Undo Flag Codereview
> created: 2026-04-13

## Summary

Review the current `--undo` implementation against `plan/undo-flag.md`.
The feature is close, but it is not complete enough to archive the source
plan yet.

`zig build test` passes, but several plan requirements are still missing or
implemented with the wrong behavior.

## Scope

This is a code-review plan for the current implementation in:

- `src/exec/trash.zig`
- `src/exec/move.zig`
- `src/exec/copy.zig`
- `src/util/UndoLog.zig`
- `src/util/clobber_undo.zig`

## Confirmed gaps vs `plan/undo-flag.md`

### 1. Shared: undo log entries are removed before undo succeeds

**Plan requirement**

- `Successful undo removes the entry from the log and rewrites the file.`
- On pre-flight failure, the newest undo entry must remain available.

**Current implementation**

- `src/exec/trash.zig:384`
- `src/exec/move.zig:327`
- `src/exec/copy.zig:403`
- `src/util/UndoLog.zig:78`

All three commands call `popLatestAndSave(...)` before pre-flight and before
filesystem restoration. `popLatestAndSave` rewrites the log immediately.

**Why this is a problem**

A failed undo currently consumes the newest log entry. That breaks the plan's
requirement that only a successful undo removes the entry.

**Required follow-up**

- Read the latest entry without mutating the log.
- Run all pre-flight checks.
- Execute the undo.
- Rewrite the log without the latest entry only after the undo succeeds.

**Proposed fix**

In `undoTrash`, `undoMove`, and `undoCopy`, replace the `popLatestAndSave` call with
a direct `read` + index. The log is read once; the last entry is used for pre-flight
and execution. Only after everything succeeds, call `write` with the remaining
entries. Corruption is handled before indexing (see Issue 5).

Delete `popLatestAndSave` from `UndoLog` — it becomes unused.

```zig
const entries = TrashUndoLog.read(ctx.arena, log_path) catch |err| switch (err) {
    error.UndoLogCorrupt => {
        try TrashUndoLog.write(log_path, &.{});
        try ctx.reporter.pushWarning("undo history was corrupt and has been reset", .{});
        return;
    },
    else => return err,
};
if (entries.len == 0) {
    util.log("nothing to undo", .{});
    return;
}
const entry = entries[entries.len - 1];

// ...pre-flight and execution...

try TrashUndoLog.write(log_path, entries[0 .. entries.len - 1]);
```

### 2. Shared: `--undo` still accepts extra operands

**Plan requirement**

- `--undo` takes no argument.

**Current implementation**

- `src/exec/trash.zig:114`
- `src/exec/move.zig:87`
- `src/exec/copy.zig:85`

Each command dispatches to undo mode before validating that no positional
arguments were supplied.

**Why this is a problem**

Commands like `trash --undo foo.txt`, `move --undo src dest`, or
`copy --undo extra` are accepted instead of rejected. That does not match the
flag contract described in the plan.

**Required follow-up**

- Reject any positional arguments when `flag_undo` is set.
- Add CLI tests for `--undo` with stray operands.

**Proposed fix**

In each command's `main()`, guard the undo dispatch with a positional check:

```zig
if (ctx.flag_undo) {
    if (ctx.positionals.len > 0) {
        try ctx.reporter.pushError("--undo takes no arguments", .{});
        ctx.reporter.EXIT_WITH_REPORT(1);
    }
    return undoXxx(&ctx);
}
```

Apply the same pattern to `trash.zig:114`, `move.zig:87`, and `copy.zig:85`.
No changes needed inside the undo functions themselves.

### 3. Move: pre-flight is missing some required parent-directory validation

**Plan requirement**

Move undo pre-flight must verify that every restore target parent used by undo
already exists and is a directory:

- `src_path` parent
- `dest_path` parent for clobber restoration
- `clobber_backup_path` parent for backup-chain restoration

**Current implementation**

- `src/exec/move.zig:340-369`
- `src/util/clobber_undo.zig:33-44`

The code checks:

- `dest_path` still exists
- `src_path` is free
- clobber paths still exist
- `src_path` parent exists and is a directory

The code does **not** check:

- `dest_path` parent exists and is a directory before clobber restore
- `clobber_backup_path` parent exists and is a directory before backup-chain
  restore

**Why this is a problem**

Undo can pass pre-flight and still fail during clobber restoration because a
required parent directory was removed after the original move completed.

**Required follow-up**

- Extend move undo pre-flight to validate every restore-target parent used by
  `util.clobber_undo.execute(...)`.
- Add tests for missing `dest_path` parent and missing `backup~` parent.

**Proposed fix**

In `undoMove`'s pre-flight loop (`move.zig:362`), after the existing
`clobber_undo.preflight` call, add a parent check guarded by `clobber.hasClobber()`:

```zig
if (clobber.hasClobber()) {
    if (dirname(file.dest_path)) |parent| {
        const parent_stat = try ctx.cwd.statNoFollow(parent);
        if (parent_stat == null or parent_stat.?.kind != .directory) {
            try ctx.reporter.pushError("undo failed: clobber restore parent missing: {s}", .{parent});
            preflight_ok = false;
        }
    }
}
```

`clobber_backup_path` is always `{dest_path}.backup~`, so its parent is identical
to `dest_path`'s parent. One check covers both trash-clobber and backup-clobber
restore paths.

### 4. Copy: pre-flight is missing required parent-directory validation for clobber restoration

**Plan requirement**

Copy undo pre-flight must verify:

- every dest file/symlink still exists
- every non-empty clobber path still exists
- every restore target parent directory used by clobber reversal already exists
  and is a directory
- directories created only by the copy are not pre-flight checked

**Current implementation**

- `src/exec/copy.zig:417-438`
- `src/util/clobber_undo.zig:33-44`

The code checks:

- dest existence for non-directory items
- existence of recorded clobber paths

The code does **not** check the parent directories needed to restore clobbered
items.

**Why this is a problem**

Copy undo can pass pre-flight, delete copied content, and then fail while
restoring a clobbered path because its parent directory no longer exists.
That is exactly the case the plan says pre-flight should prevent.

**Required follow-up**

- Add parent-directory validation for every clobber restore target.
- Cover both trash-clobber and backup-clobber restore paths in tests.

**Proposed fix**

Same pattern as Issue 3. In `undoCopy`'s pre-flight loop (`copy.zig:425`), after
the existing `clobber_undo.preflight` call, add:

```zig
if (clobber_info.hasClobber()) {
    if (std.fs.path.dirname(file.dest_path)) |parent| {
        const parent_stat = try ctx.cwd.statNoFollow(parent);
        if (parent_stat == null or parent_stat.?.kind != .directory) {
            try ctx.reporter.pushError("undo failed: clobber restore parent missing: {s}", .{parent});
            preflight_ok = false;
        }
    }
}
```

`clobber_undo.execute` always restores to `file.dest_path`, so its parent directory
must exist before any clobber restore runs.

### 5. Shared: corrupt undo logs are not reset and warned as planned

**Plan requirement**

- Corrupt / unparseable log: reset the file automatically and warn that prior
  undo history was discarded.
- On append after a successful command, overwrite the file with a fresh log
  containing only the current entry.
- On `--undo`, rewrite the file as an empty log, warn, then treat it as
  "nothing to undo".

**Current implementation**

- `src/exec/trash.zig:175-177`
- `src/exec/move.zig:320-322`
- `src/exec/copy.zig:397-398`
- `src/exec/trash.zig:384-389`
- `src/exec/move.zig:327-332`
- `src/exec/copy.zig:403-408`
- `src/util/UndoLog.zig:28-44`

Successful command paths silently discard append failures with `catch {}`.
Undo paths treat `error.UndoLogCorrupt` as a hard error and tell the user to
manually delete the file.

**Why this is a problem**

A successful trash/move/copy command can fail to record undo history without
any warning when the existing log is corrupt. `--undo` also does not match the
new reset-and-warn behavior.

**Required follow-up**

- Reset corrupt logs automatically instead of requiring manual deletion.
- Emit a warning that prior undo history was discarded.
- Add regression tests for corrupt-log handling on both append and `--undo`.

**Proposed fix**

Centralize the corruption fallback inside `appendAndSave` in `src/util/UndoLog.zig`.
No new helper functions are needed — the undo path uses `read` and `write` directly
(see Issue 1).

**Append path** — inside `appendAndSave`, intercept `error.UndoLogCorrupt` from
`read` and fall back to an empty entry list, then continue writing a fresh log
with only the new entry. Change the return type from `!void` to `!bool`. Return
`true` when the existing log was corrupt and reset, `false` on a clean append.
The three call sites update from `catch {}` to:

```zig
const was_reset = TrashUndoLog.appendAndSave(arena, path, files) catch false;
if (was_reset) {
    try ctx.reporter.pushWarning("undo history was corrupt and has been reset", .{});
}
```

**Undo path** — handled by the Issue 1 fix. Each undo function calls `read`
directly, catches `error.UndoLogCorrupt`, writes an empty log with `write`, warns,
and returns early. No extra helpers needed.

## Missing features checklist

- [ ] Keep the newest undo entry on failed undo pre-flight or failed undo execution.
- [ ] Enforce `--undo` as a no-argument flag in `trash`, `move`, and `copy`.
- [ ] Add move undo pre-flight checks for all restore-target parents.
- [ ] Add copy undo pre-flight checks for all clobber-restore parents.
- [ ] Add corrupt-log reset behavior with warnings for append and `--undo`.
- [ ] Add regression tests for the cases above.

## Archive decision

Do not archive `plan/undo-flag.md` yet.

The implementation is functional enough to pass the current test suite, but it
still does not meet all of the plan's shared and pre-flight correctness rules.
