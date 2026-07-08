# Milestone 16 — View & Workflow Memory

**Goal:** Remember how users work in specific folders and make repeated
workflows faster.

## Scope

- Per-folder view settings: view mode, sort, group, icon sizing, column widths,
  preview-pane visibility, and hidden-file preference.
- Workspace profiles: named tab/pane layouts with roots, filters, and view
  settings.
- Custom toolbar: user-selectable actions for common commands.
- Command palette improvements: recent commands, conflict visibility for
  shortcuts, and command metadata.

## Implementation Notes

- Store folder settings separately from session state so temporary tabs do not
  rewrite durable preferences unexpectedly.
- Use stable folder identity by standardized path first; bookmark data can be a
  later upgrade if sandboxing becomes relevant.
- Workspace profiles should be explicit user saves, not automatic snapshots.

## Test Focus

- Backward-compatible settings decoding.
- Folder-settings lookup precedence.
- Workspace profile round-trip and restore.
- Shortcut conflict reporting remains deterministic.

