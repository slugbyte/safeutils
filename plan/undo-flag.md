# Undo Flag
> created: 2026-04-12

## Summary

Add `--undo` / `-u` to the trash, move, and copy CLIs. Undo reverts the
most recent operation by restoring the filesystem to its prior state. Each
CLI has its own undo log stored as a `.zon` file in the safeutils XDG cache
directory.

Phase 1 implements trash undo. Phase 2 adds move and copy undo with full
clobber reversal.

## Shared Design

### Undo log location

```
$XDG_CACHE_HOME/safeutils/trash-undo.zon
$XDG_CACHE_HOME/safeutils/move-undo.zon
$XDG_CACHE_HOME/safeutils/copy-undo.zon
```

If `XDG_CACHE_HOME` is unset, fall back to `~/.cache/safeutils/`.
Create the directory if it doesn't exist.

### Undo log format

Each file is a ZON array of entries capped at 3. Newest entry is last.
All stored paths are absolute. Capture every absolute path needed for undo
before mutating the filesystem for that item. Trash-backed entries must
also store the exact `trashinfo_path` used on Linux so `--trash-dir` and
`--trash-info-dir` overrides are captured explicitly. Zig's built-in ZON
parser and formatter handle serialization.

### Common rules

- Max 3 entries per log. When appending, drop the oldest if at capacity.
- Capture undo metadata in memory during command execution, but only
  persist a log entry if the entire command completes successfully.
- `--undo` takes no argument — always targets the newest (last) entry.
- Successful undo removes the entry from the log and rewrites the file.
- Empty or missing log: report "nothing to undo" and exit 0.
- Corrupt / unparseable log: reset the file automatically and warn that
  prior undo history was discarded. Do not attempt partial recovery.
  On append after a successful command, overwrite the file with a fresh
  log containing only the current entry. On `--undo`, rewrite the file
  as an empty log, warn, then treat it as "nothing to undo".
- Undo pre-flight must validate that every restore target's parent
  directory already exists and is a directory. Do not auto-create parent
  directories during undo.
- `--undo` is mutually exclusive with all other mode flags.

### Flag

| flag | short | value | description |
|------|-------|-------|-------------|
| `--undo` | `-u` | none | Revert the most recent operation |

---

## Phase 1: Trash Undo

### Log entry format

```zon
.{
    .timestamp = 1744444800,
    .files = .{
        .{
            .original_path = "/home/user/project/foo.txt",
            .trash_path = "/home/user/.local/share/Trash/files/foo.txt",
            .trashinfo_path = "/home/user/.local/share/Trash/info/foo.txt.trashinfo",
        },
    },
}
```

`trashinfo_path` is empty on non-Linux.

### Recording

Before mutating each path, capture its absolute undo metadata in memory.
After the existing trash loop completes, if the entire command succeeded,
collect every trashed file's `{original_path, trash_path, trashinfo_path}`
data and:

1. Read and parse existing `trash-undo.zon`. If it is missing, start with
   an empty array. If it is corrupt, warn, discard prior history, and
   start with an empty array.
2. Append new entry with current timestamp.
3. Trim to 3 entries (drop oldest).
4. Format and write `trash-undo.zon`.

If the command exits non-zero, do not write an undo entry.

### Undo pre-flight (all-or-nothing)

For every file in the entry, before moving anything:

- **Trash file exists:** `trash_path` must still be present.
- **No conflict:** `original_path` must not already exist.
- **Parent exists:** the parent directory of `original_path` must exist
  and be a directory.

If any check fails, report which files have problems and exit non-zero.

### Undo execution

For each file in the entry:

1. Move `trash_path` back to `original_path`.
2. On Linux: delete the recorded `trashinfo_path`.

Remove the entry from the log and rewrite.

---

## Phase 2: Move and Copy Undo

### Clobber reversal (shared concept)

Both move and copy support `--trash` and `--backup` clobber styles. Undo
must reverse the clobber to fully restore the prior state. The clobber
reversal logic is identical between move and copy and can be shared code.

**Clobber variants to record per destination item:**

- **None:** dest didn't exist. Nothing to restore.
- **Trash:** original dest was trashed. Record `clobber_trash_path` and,
  on Linux, `clobber_trashinfo_path`.
- **Backup:** original dest renamed to `dest.backup~`. Record
  `clobber_backup_path`. If `backup~` already existed and was trashed,
  also record `clobber_backup_trash_path` and, on Linux,
  `clobber_backup_trashinfo_path`.

**Clobber undo execution (per destination item, after primary undo):**

1. If trash clobber: move `clobber_trash_path` back to `dest_path`.
   On Linux, then delete `clobber_trashinfo_path`.
2. If backup clobber: move `clobber_backup_path` back to `dest_path`.
   Then if `clobber_backup_trash_path` is set, restore it to
   `clobber_backup_path`. On Linux, then delete
   `clobber_backup_trashinfo_path`.

### Move undo

#### Log entry format

```zon
.{
    .timestamp = 1744444800,
    .files = .{
        .{
            .src_path = "/home/user/project/a.txt",
            .dest_path = "/home/user/other/b.txt",
            .clobber_trash_path = "",
            .clobber_trashinfo_path = "",
            .clobber_backup_path = "",
            .clobber_backup_trash_path = "",
            .clobber_backup_trashinfo_path = "",
        },
    },
}
```

Empty string means no clobber for that field. `*_trashinfo_path` fields are
empty on non-Linux.

#### Recording

Before mutating each move item, capture `{src_path, dest_path}` and the
clobber paths that may be used. The clobber info comes from the move
function's clobber block — record the trash path and trashinfo path that
were produced, or the backup path and any backup-trash paths that were
produced.

Write the entry only if all moves in the command complete successfully.
If the command exits non-zero, do not write an undo entry. If the existing
`move-undo.zon` is corrupt, warn, discard prior history, and overwrite it
with a fresh log containing only the new entry.

#### Undo pre-flight (all-or-nothing)

- Every `dest_path` must still exist.
- Every `src_path` must be free (nothing at the original location).
- Every non-empty clobber path must still exist (trash file, backup file).
- Every restore target parent directory used by undo must already exist
  and be a directory (`src_path` parent, `dest_path` parent for clobber
  restore, and `clobber_backup_path` parent for backup-chain restore).

#### Undo execution (per file)

1. Move `dest_path` back to `src_path`.
2. Reverse clobber (see shared clobber undo above).

### Copy undo

#### Log entry format

```zon
.{
    .timestamp = 1744444800,
    .files = .{
        .{
            .dest_path = "/home/user/other/b.txt",
            .kind = .file,
            .dir_created = false,
            .clobber_trash_path = "",
            .clobber_trashinfo_path = "",
            .clobber_backup_path = "",
            .clobber_backup_trash_path = "",
            .clobber_backup_trashinfo_path = "",
        },
    },
}
```

- `kind`: `.file`, `.directory`, or `.sym_link`.
- `dir_created`: true if the directory was created by the copy, false if
  it pre-existed (merge mode). Only meaningful for `.directory` entries.

#### Recording

Before mutating each copy item, capture the absolute paths needed for
undo. After `performCopies` completes, record every item from the expanded
copy list. For directory entries, check whether `makeDir` created the
directory or hit `PathAlreadyExists` to set `dir_created`.

Write the entry only if all copies complete successfully. If the command
exits non-zero, do not write an undo entry. If the existing
`copy-undo.zon` is corrupt, warn, discard prior history, and overwrite it
with a fresh log containing only the new entry.

#### Undo pre-flight

- Every dest file/symlink must still exist.
- Every non-empty clobber path must still exist, including directory
  clobber paths.
- Every restore target parent directory used by clobber reversal must
  already exist and be a directory.
- Directories created only by the copy are NOT checked in pre-flight
  (best-effort cleanup).

#### Undo execution (reverse order — children before parents)

1. Delete copied dest files and symlinks.
2. Delete copied `dir_created` directories deepest-first so any copied
   replacement subtree is removed before clobber restoration.
3. Reverse clobber for every recorded destination item, including
   directories (see shared clobber undo above).
4. If a `dir_created` directory is still non-empty after clobber
   restoration, skip it with a warning. Pre-existing dirs are left
   untouched.

Copied content removal for files and symlinks stays all-or-nothing.
Best-effort cleanup only applies to extra directories created by the copy
that have no prior state to restore. Restoring a previously clobbered
file, symlink, or directory is part of correctness, not optional cleanup.

---

## Out of scope

- `--undo N` or entry selection — always undo the most recent.
- `--undo-fzf` or interactive picker.
- Atomicity guarantees on log writes (crash mid-operation = no undo record;
  `--revert` and manual recovery still work).
- Undo for partial command failures. Undo history only records fully
  successful commands; if a command exits non-zero, no undo entry is
  written even if some filesystem changes already happened.
- Recording --revert, --fetch, or --undo operations in any log.
- Undo for copy `--create` (the created dest directory is left behind if
  it was the `--create` target; only its contents are undone).
