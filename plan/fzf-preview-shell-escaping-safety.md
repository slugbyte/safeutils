# Fzf Preview Shell Escaping Safety
> created: 2026-04-12

## Goal
Make `trash` fzf preview command construction shell-safe and robust for paths with spaces, quotes, and shell metacharacters.

## Problem
`src/exec/trash.zig` builds the fzf preview command as a shell-interpreted string. Dynamic values such as the selected trash item placeholder, `--trash-dir`, and `--trash-info-dir` are interpolated directly. That can break preview behavior for ordinary paths with spaces and creates avoidable shell-injection risk for metacharacters.

## Scope
- Preview command construction in `src/exec/trash.zig`
- Quoting and escaping rules for all dynamic preview-command values
- Regression tests for paths and selections with shell-sensitive characters

## Non-goals
- Reworking overall `trash` CLI behavior outside preview command construction
- Changing unrelated fzf UI behavior or preview formatting
- Relying on filename filtering as a substitute for shell-safe quoting

## Plan
1. Trace how `fzfTrash()` assembles the preview command and identify every dynamic shell-exposed value.
2. Define one explicit shell-quoting strategy for POSIX shell command strings and apply it consistently.
3. Ensure the selected fzf item is passed to `trash --fzf-preview` as one safe argument.
4. Ensure `--trash-dir` and `--trash-info-dir` overrides remain correct when they contain spaces or shell metacharacters.
5. Add regression tests or focused repro coverage for whitespace, quotes, and other shell-sensitive characters.

## Risks
- Fixing some dynamic fields but leaving others unescaped.
- Double-quoting or over-escaping values so preview stops working.
- Assuming ASCII-only names are shell-safe.

## Verification
- Preview works when trash paths contain spaces.
- Preview works when override paths contain shell metacharacters.
- Selected entries are passed to `trash --fzf-preview` as a single argument.
- Dynamic values in the preview command cannot alter command structure through shell parsing.
