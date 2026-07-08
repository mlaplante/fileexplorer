# Milestone 15 — Reliability Core

**Goal:** Make destructive and long-running file operations trustworthy before
adding more power features. This milestone introduces operation planning,
conflict choices, an operation queue, progress UI, retry/cancel behavior, and
history.

## Scope

- Operation conflict planner for copy, move, and sync targets.
- Conflict choices: replace, keep both, skip, and apply-to-all.
- Operation queue model with pending/running/succeeded/failed/cancelled states.
- Progress reporting for large copy/move/sync/archive operations where the
  platform APIs expose useful progress.
- Retry failed items from an operation summary.
- Operation history for recent copy/move/trash/sync/archive jobs.
- Sync preview upgrades: conflict detail rows and selected conflict policy.

## Implementation Notes

- Start in Core with pure planning types, then wire existing file operations.
- Preserve current behavior until a UI path can present conflicts explicitly.
- Keep undo grouping at operation boundaries, not per-file rows.
- Large operation cancellation must leave partial results visible and undoable
  when possible.

## Test Focus

- Conflict planning for no conflict, existing target, case-only names,
  folder-into-itself, keep-both names, replace decisions, skip decisions, and
  apply-to-all policy.
- Operation queue state transitions and retry filtering.
- Existing file operation tests must keep passing after routing through the new
  planner.

