# FileExplorer v2 — Deferred-Debt Paydown Design

**Date:** 2026-07-07
**Status:** Approved
**Scope:** Pay off every item v1 explicitly deferred (milestone plan completion notes + 6b whole-project debt list). No new spec-level features — App Store distribution, cloud integrations, themes, column view, and file content search remain out of scope.

## Goal

Two milestones, each leaving a working app, continuing the v1 cadence:

- **Milestone 7 — Session & Settings Persistence** (foundation: the settings store is a dependency for M8's JPG quality preference)
- **Milestone 8 — Interaction Debt** (everything else deferred from v1)

## Approved decisions

1. **v2 scope = all deferred debt** (13 items), not just the headline four.
2. **Full session restore** on relaunch: tabs, dual-pane layout, folder per pane, active tab/pane indices, per-pane filters, view mode, showHidden, sort order, and recent folders.
3. **Finder-parity drop semantics:** same-volume drop = move, ⌥-drag = copy, cross-volume drop defaults to copy.
4. **JPG quality via Convert submenu presets** (60/80/90/100), last choice remembered in settings. No Settings window in v2.
5. **Two-milestone structure** (M7 then M8), one branch + plan doc each.

---

## Milestone 7 — Session & Settings Persistence

### New Core types

**`SessionSnapshot`** — a `Codable` value-type mirror of the persistable slice of the session object graph:

- `tabs: [TabSnapshot]`, `activeTabIndex`
- `TabSnapshot`: `panes: [PaneSnapshot]` (1–2), `activePaneIndex`
- `PaneSnapshot`: folder URL (as path string), `FilterState`, view mode, `showHidden`, sort order
- `recentFolders: [String]`

`FilterState` is already an `Equatable`/`Sendable` struct of preset tokens; it gains `Codable` conformance directly. Navigation history and selection are **not** persisted (fresh per launch — matches Finder behavior and avoids stale-URL churn).

**`SettingsStore`** — a small `Codable` settings struct with load/save. First field: `jpegQuality: Double` (default 0.85). M8 features read/write it; future settings get a home without new plumbing.

**`SessionPersister`** — load/save of `session.json` and `settings.json` in `~/Library/Application Support/FileExplorer/` (directory injectable for tests):

- **Save:** atomic writes; debounced on state change plus a synchronous save on quit.
- **Restore:** rebuilds `SessionState` from the snapshot at launch. Each pane falls back to the nearest existing ancestor via the existing `URL.ancestorChain` pattern when its saved folder no longer exists.
- **Failure posture:** corrupt or missing JSON → clean default session, never a crash or user-facing error.

### App wiring

`FileExplorerApp` loads the snapshot before constructing `SessionState`, and registers change-driven saves (observation-based debounce) plus a quit-time save.

## Milestone 8 — Interaction Debt

### Batch tools
- **Convert quality:** `ImageConverter` quality parametrized (was fixed 0.85). Convert-to-JPG context submenu gains Quality presets 60/80/90/100; the chosen value persists to `SettingsStore`.
- **Convert selects outputs:** `convertSelected` selects its output files after reload — same pattern `batchRename` received in 6b (keeps Quick Look refresh working).
- **Rename swaps:** `RenamePlan` supports A↔B (cycle) renames via two-phase temp-name rename instead of conservatively blocking on `existingFile`.
- **Direct-pane unification:** batch-rename and rename context-menu actions take the pane they were invoked on (direct-pane pattern used by convert/compress/size) instead of `session.activePane`, fixing right-click on an inactive pane.

### Selection & drag/drop
- **Grid multi-select:** `ThumbnailGridView` gets ⌘-click toggle and ⇧-click range selection, matching the Table's semantics. Selection state already lives on `PaneState`, so this is view-layer only.
- **Drop into pane:** Finder parity (decision 3). Modifier read at drop time; volume comparison decides the default. Both paths route through the existing `FileOperationService` and undo registration. The pure decision function (modifiers × volumes → move/copy) lives in Core and is unit-tested.

### Browse polish
- **Symlink badge:** surface the existing `FileEntry.isSymlink` as a badge in table rows and grid cells.
- **Volumes:** sidebar observes `NSWorkspace` mount/unmount notifications and refreshes the volume list; sidebar highlights the item matching the active pane's current location.
- **⌘W on last tab:** closes the window (was a no-op).

### Filters
- **Custom date/size ranges:** popovers with `@Observable` models and manual bindings (the established no-`@State` workaround). Custom ranges join the existing preset tokens in `FilterState` so they persist with the session and stay testable in `FilterEngine`. The new fields are optional, so `session.json` files written by M7 still decode (forward-compatible snapshot).

### Internal cleanups (no user-visible behavior change)
- Unify `showHidden` invalidation with the `didSet` auto-resort convention on `PaneState`.
- Hoist `hoverModel` off the view struct (latent lifecycle issue noted in M5).
- Generation-counter coalescing in the thumbnail pipeline for very large folders.
- Remove or wire the unused `RenameRules.isNoOp`; revisit "Calculate Size" being enabled for plain files.

---

## Testing

TDD against the executable harness (`swift run FileExplorerTests`) — CLT-only toolchain constraints hold: no `swift test`, no `xcodebuild`, no `@State`.

Unit-testable in Core: snapshot round-trip (encode → decode → equivalent graph), ancestor fallback, corrupt/missing JSON recovery, settings load/save, swap-rename planning and execution, drop decision function, custom-range filtering, quality parameter pass-through.

MANUAL walkthrough (TCC blocks agent-driven UI automation): popover interactions, context-menu submenus, actual drag-and-drop gestures, grid modifier-clicks, mount/unmount refresh.

## Error handling

- Persistence failures are silent-but-logged; the app never blocks launch on bad state files.
- Swap renames that fail mid-two-phase restore original names (same all-or-surface posture as existing file ops; failures land in the status bar).
- Drop-as-move failures fall back to reporting via the status bar with undo untouched.

## Out of scope (v2)

App Store distribution / signing / auto-update, cloud storage, custom themes, Finder-style column view, file content search, Settings window, drag-rectangle grid selection, multi-frame image conversion beyond frame 0.
