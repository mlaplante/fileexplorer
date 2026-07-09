# Open in Terminal / Editor + User Scripts Menu — Design

**Date:** 2026-07-09
**Status:** Approved (user directive: continue autonomously, delegate implementation to Codex)

## Problem

FileExplorer can be *opened from* a terminal (`fx`), but there is no way back:
no command jumps from the current pane to a terminal or code editor, and no
hook exists for user automation over the current selection. Every rival power
file manager (Path Finder, ForkLift, Nimble Commander) ships both.

## Goal

- **Open in Terminal** — open the active pane's folder (or the single selected
  folder) in a user-configured terminal app.
- **Open in Editor** — open the selection (or the current folder when nothing
  is selected) in a user-configured editor app.
- **Scripts menu** — run user-supplied executables from
  `~/Library/Application Support/FileExplorer/Scripts` with the selection as
  arguments and the pane folder as cwd, with success/failure feedback.
- All three reachable from the File menu, the file context menu, and the
  command palette; the two Open commands get customizable shortcuts via the
  existing Shortcuts settings.

## Approach (chosen): generic open-with + direct Process launch

One mechanism serves both Open commands:
`NSWorkspace.open(_:withApplicationAt:configuration:)` pointed at a
user-picked `.app` bundle. Terminal.app, iTerm2, and Ghostty all open a window
at a directory handed to them this way; editors likewise open files/folders.
Scripts run via `Process` directly (shebang respected), never through a shell.

**Rejected:** AppleScript automation (fragile, needs Automation TCC prompts,
per-app dialects) and per-app adapter plugins (YAGNI — the generic open-with
call covers every mainstream terminal and editor).

## Semantics decisions

- **Settings:** new "Integrations" group: *Terminal app* and *Editor app*,
  each picked via `NSOpenPanel` restricted to `.app` bundles under
  `/Applications` et al. Stored as bundle **paths** (strings) in
  `SettingsModel`, persisted with the existing settings round-trip. Defaults:
  Terminal = `/System/Applications/Utilities/Terminal.app` if present, Editor
  = unset.
- **Target resolution:**
  - Open in Terminal → the single selected *folder* if exactly one folder is
    selected, else the pane's current folder.
  - Open in Editor → all selected items; empty selection falls back to the
    pane's current folder.
- **Unconfigured/missing app:** menu item disabled when unset; if the stored
  bundle path no longer exists, invoking shows an alert with an "Open
  Settings" button.
- **Scripts folder:** `~/Library/Application Support/FileExplorer/Scripts`,
  created lazily by "Open Scripts Folder". Menu lists executable regular
  files (and executable symlinks), sorted by name, re-read each time the menu
  opens — no watcher. Non-executables are skipped silently; unreadable folder
  → single disabled explanatory item.
- **Script invocation:** argv = selected file paths (pane folder appended as
  sole argument when selection is empty — scripts always receive ≥1 path);
  cwd = pane's current folder; environment inherited. stdout ignored, stderr
  captured (ring-capped at 4 KB).
- **Feedback:** exit 0 → transient pane banner "*name* finished" (reuses the
  CompareBannerView pattern, auto-dismisses). Nonzero exit → alert with
  script name, exit code, captured stderr. Either way the active pane
  reloads. 60 s soft timeout: banner flips to "*name* still running…" and the
  process is left alone (never killed); its eventual exit still reports.
- **Concurrency:** multiple scripts may run at once; completion feedback is
  serialized through the main actor.

## Components

| Unit | Kind | Responsibility |
|---|---|---|
| `ScriptLister` (new, Core) | pure enum | filter a directory listing to executable entries, sorted by name |
| `ScriptInvocationPlanner` (new, Core) | pure enum | (selection, pane folder) → argv + cwd; Open-in-Terminal/Editor target resolution |
| `ScriptResultFormatter` (new, Core) | pure enum | (name, exit code, stderr, elapsed) → banner/alert text, stderr truncation |
| `AppLauncher` (new, app) | thin shim | NSWorkspace open-with; bundle-exists check |
| `ScriptRunner` (new, app) | @Observable | Process launch, timeout tracking, completion → banner/alert state |
| `SettingsModel` (modify) | @Observable | `terminalAppPath`, `editorAppPath` persisted fields |
| `SettingsScenes` (modify) | SwiftUI | Integrations group with two app pickers |
| `FileExplorerApp` / `FileActionsMenu` / `PaletteCoordinator` (modify) | SwiftUI | menu items, context-menu entries, palette commands, shortcut wiring, banner display |

## Error handling

- Missing configured app → alert + "Open Settings" button.
- Script fails to launch (`Process.run` throws) → same alert path as nonzero
  exit, with the thrown error text in place of stderr.
- Scripts folder unreadable → disabled explanatory menu item.

## Testing

Executable harness (`swift run FileExplorerTests`), no UI tests:
- `ScriptListerTests`: executable filtering, symlink handling, sort, empty
  and unreadable folders (real temp dirs).
- `ScriptInvocationPlannerTests`: argv/cwd for selection vs. empty selection;
  terminal target resolution (single folder selected / file selected /
  multi-selection → pane folder).
- `ScriptResultFormatterTests`: success/failure/timeout text, stderr 4 KB cap.
- `SettingsModelTests` additions: new fields round-trip and legacy-decode
  (decodeIfPresent).

Manual walkthrough items (real Terminal/iTerm2/editor launches, banner feel,
long-running script) join the pending manual list.
