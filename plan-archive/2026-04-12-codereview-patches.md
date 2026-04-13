# Codereview Patches
> created: 2026-04-12

> [!warning] Archived
> This plan has been archived and is kept for reference only. It does not
> reflect active work.

## Patch 1: Fix `move` multi-source destination handling

### Goal
Ensure `move src.. dest` rejects invalid multi-source destination forms before any filesystem mutation, with the first patch focused on the missing trailing-`/` bug for directory targets.

### Problem
`src/exec/move.zig` documents that multi-source moves require the destination to be a directory with a trailing `/`. The current validation does not fully enforce that rule, so a command like `move -t a b out` can validate as if `out` were a parent directory and then execute as repeated exact-path replacement of `out`.

### Scope
- Multi-source path validation in `src/exec/move.zig`
- Help text and error messages related to multi-source destination rules
- Targeted tests for accepted and rejected destination forms

### Non-goals
- Changing intentional single-source exact-destination semantics such as `move -t file dir`
- Reworking clobber policy beyond what is needed to make multi-source handling correct
- Fixing unrelated `move`, `copy`, or `trash` review findings in this patch

### Plan
1. Trace the multi-source code path in `src/exec/move.zig` and document the exact mismatch between validation and execution.
2. Tighten validation so multi-source moves require a destination path with trailing `/` and reject bare directory paths before any move occurs.
3. Ensure derived child destination paths are only constructed after that invariant is established.
4. Update help text and diagnostics so the rule is explicit and consistent with runtime behavior.
5. Add regression tests covering valid multi-source directory targets and invalid bare-directory targets.

### Risks
- Overcorrecting and breaking intended single-source exact-path behavior.
- Leaving runtime paths that still interpret a bare destination differently from validation.
- Missing basename-collision cases that should be handled in a later patch.

### Verification
- `move a b out` fails with a clear error before moving anything.
- `move -t a b out` fails with the same clear error before moving anything.
- `move a b out/` moves both files into `out/`.
- Existing single-source behaviors remain unchanged.

## Follow-up docs note: `move` multi-source ordering

### Goal
Clarify that duplicate multi-source destination resolution is intentional and order-dependent, rather than adding collision detection.

### Help text explainer
> Multi-source moves are applied left-to-right. If multiple sources resolve to the same destination path, later sources take priority.

## Follow-up docs note: `move` partial completion

### Goal
Replace the current all-or-nothing guarantee with wording that matches the implementation.

### Help text explainer
> Move validates all paths before starting, but runtime filesystem errors can still cause partial completion.

## Follow-up behavior note: `trash` restore conflicts

### Goal
Make restore operations conservative by failing when the destination path already exists.

### Intended behavior
- `trash --revert <name>` fails if the original destination path already exists.
- `trash --fetch <name>` fails if the destination path in the current directory already exists.

### Help text explainer
> `--revert` and `--fetch` will fail if the destination path already exists.

## Follow-up behavior note: `copy --merge` conflict handling

### Goal
Narrow merge-mode special handling so only directory-on-directory conflicts are merged automatically.

### Intended behavior
- In `copy --merge`, an existing destination directory is preserved without clobber only when the source item is also a directory.
- For file->directory and symlink->directory conflicts, normal clobber rules apply.
- Without a clobber flag, those conflicts are rejected during validation.
- With `--trash` or `--backup`, the destination is replaced before the copy proceeds.

### Behavior summary
- dir -> dir: merge
- dir -> file/link: reject without clobber, replace with clobber
- file/link -> dir: reject without clobber, replace with clobber
- file/link -> file/link: reject without clobber, replace with clobber

## Follow-up behavior note: `trash` broken symlink restore and preview

### Goal
Treat broken symlinks in trash as first-class entries that can still be previewed, fetched, and reverted.

### Intended behavior
- `trash` restore and preview paths inspect trashed entries with no-follow semantics.
- A broken symlink in trash is still recognized as a symlink.
- `--revert`, `--fetch`, and fzf preview continue to work for broken symlinks.

### Implementation note
- Use `statNoFollow()` when inspecting trashed entries in `RevertInfo.init()`.

## Follow-up behavior note: `move` broken destination symlink clobber

### Goal
Make move-time destination conflict handling treat broken symlinks as existing paths that participate in clobber behavior.

### Intended behavior
- Destination inspection during `move` execution uses no-follow semantics.
- A broken destination symlink is treated as an existing destination path.
- With `--trash` or `--backup`, broken destination symlinks are trashed or backed up before the move proceeds.

### Implementation note
- In `src/exec/move.zig`, replace execute-time `exists()`-style destination checks with `statNoFollow()`-based checks.

## Follow-up behavior note: `trash` strict flag validation

### Goal
Make `trash` CLI mode selection and option parsing explicit, predictable, and fail-fast.

### Intended behavior
- `trash` mode flags are mutually exclusive.
- Invalid or missing values for value-taking flags produce explicit parse errors.
- `--viu-width` rejects invalid numeric input instead of silently falling back.
- `--fzf-preview-window` rejects missing values.

### Policy
- Normal trashing by positional arguments, `--fetch`, `--revert`, `--fetch-fzf`, `--revert-fzf`, and `--fzf-preview` are separate modes and may not be combined.
