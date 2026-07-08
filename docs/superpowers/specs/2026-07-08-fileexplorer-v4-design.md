# FileExplorer v4 — Design Spec

**Date:** 2026-07-08
**Status:** Approved
**Scope:** Close the remaining Finder-parity gaps identified in the post-v3 gap analysis (items 1–14). Two milestones continuing the v1–v3 cadence: **M13 — Finder-parity quick wins** (items 1–7) and **M14 — Finder power features** (items 8–14). Each milestone leaves a working app. Implementation is delegated to Codex agents working from the milestone plan docs.

## Approved decisions

1. **v4 = gap-analysis items 1–14**, split by effort: M13 (small, mostly view-layer + one Core helper each), M14 (features that add new models or AppKit bridges).
2. **Aliases are symlinks.** "Make Alias" creates a POSIX symlink (`name alias`, collision-suffixed), not a Finder alias file — consistent with the app's existing symlink-first read side.
3. **Put Back is app-recorded.** A persisted trash registry (`trash-registry.json` in App Support) maps trashed URLs → original paths for items trashed *by this app*. "Put Back" appears for registered items when browsing a Trash folder. We do not parse Finder's private `.DS_Store` put-back data.
4. **Preview pane is per-tab**, follows the active pane's selection, toggled with ⌥⌘P, persisted in the session snapshot (optional field — old snapshots still decode).
5. **Group By is a pure Core transform** (`Grouper`) with four axes: none, kind, date modified (Finder-style buckets: Today/Yesterday/Previous 7 Days/Previous 30 Days/Earlier), size (buckets). List view renders groups as `Table` sections; icon grid renders section headers. Persisted per pane in the snapshot (optional field).
6. **Share uses `NSSharingServicePicker`** anchored to the clicked row via a small AppKit bridge (same posture as `QuickLookController`). AirDrop comes for free.
7. **Finder comments** are read via `MDItemCopyAttribute(kMDItemFinderComment)` and written via the `com.apple.metadata:kMDItemFinderComment` xattr (binary-plist string), same mechanism as `TagWriter`. Doc note: Finder may show a stale comment until Spotlight reindexes; acceptable.
8. **Eject** only offers itself for volumes whose resource values report ejectable/removable, never the root volume. Failures land in the status bar (existing error posture).
9. **Spring-loading** uses per-row `dropDestination` `isTargeted` + a 700 ms timer; navigating cancels cleanly if the drag leaves the row.
10. **No new settings surface** beyond: Recents section cap (fixed 8, not configurable), spring-load delay (fixed), group-by/preview-pane state living in the session snapshot.

## Constraints (unchanged from v1–v3)

CLT-only toolchain: no `xcodebuild`, no `swift test`, no `@State`/`@FocusState` (use `@Observable`/`@Bindable`; `@Observable` models owned by `FileExplorerApp`, never by view structs). Tests run via the executable harness (`swift run FileExplorerTests`). TCC blocks agent-driven UI automation, so gesture/panel behaviors land on the manual walkthrough list. Snapshot fields added in v4 must be optional/defaulted so v3 `session.json` files still decode.

---

## Milestone 13 — Finder-parity quick wins

### 1. Icon-grid arrow-key navigation
The grid already records every cell's frame in `PaneState.rubberBandFrames: [URL: CGRect]`. A pure Core `GridNavigator` picks the geometric neighbor for ↑/↓/←/→ from those frames; the view layer feeds it key presses (`onMoveCommand` / `onKeyPress`). Plain arrows replace the selection with the neighbor; ⇧-arrows extend using the existing anchor semantics (`selectionAnchor`). No selection → arrow selects the first visible cell.

### 2. Eject volumes
`VolumesModel.Place` gains `isEjectable` (from `volumeIsEjectableKey`/`volumeIsRemovableKey`, root excluded). Sidebar volume rows get a context-menu "Eject" (and an eject glyph button) calling `NSWorkspace.shared.unmountAndEjectDevice(at:)` off-main; failure surfaces in the active pane's status bar. If the active pane was inside the ejected volume, the existing missing-folder fallback navigates to the nearest existing ancestor (root fallback: home).

### 3. Recents in the sidebar
New "Recents" sidebar section under Favorites: the first 8 of `SessionState.recentFolders`, folder-icon rows behaving like Favorites rows (navigate on click). Section context menu: "Clear Recents" → new `SessionState.clearRecentFolders()`. Deduped against built-in favorite URLs so Home/Desktop/etc. don't show twice.

### 4. Make Alias (symlink)
`FileOperationService.symlink(_ sources: [URL]) -> [ItemResult]` creates `name alias` (collision-suffixed via `CollisionNamer`) siblings pointing at each source. Context-menu "Make Alias". Undo = delete-as-undo (`UndoRecorder.recordCreation`). Created symlinks are selected after reload (M8 pattern).

### 5. Free space in the status bar
Status bar right side shows "X GB available" for the current folder's volume (`volumeAvailableCapacityForImportantUsageKey`, `ByteCountFormatter`), refreshed on navigation and directory reload. Fetch failure (network volume, etc.) → the label is simply omitted.

### 6. Sort By menu
View menu gains a "Sort By" submenu — Name / Size / Kind / Date Modified — with a checkmark on the active axis; selecting the active axis toggles ascending/descending. Writes `pane.sortOrder` (the same `KeyPathComparator` state the list headers drive), so it works in all three view modes. Pure helper maps menu choice ↔ comparator (unit-tested round-trip with the existing `SortTokenCoder`).

### 7. New Folder with Selection
Context-menu item (selection non-empty): "New Folder with Selection (N Items)". Creates a collision-safe "untitled folder" via the existing `FileOperationService.newFolder`, moves the selection in, groups both into ONE undo step (`beginUndoGrouping`/`endUndoGrouping`, same pattern as sync), selects the new folder, and opens the rename sheet. Partial move failures aggregate to the status bar; the folder stays.

## Milestone 14 — Finder power features

### 8. Group By
`PaneState.groupBy: Grouper.Axis` (`none | kind | dateModified | size`, `String`-raw `Codable`). Core `Grouper.group(_ entries: [FileEntry], by: GroupBy) -> [FileGroup]` (`FileGroup`: title + entries) applied AFTER filter+sort; group ordering is fixed per axis (kind alphabetical, date newest-bucket first, size largest-bucket first). List view: `Table` sections; grid: header rows in the `LazyVGrid`. View menu "Group By" submenu mirrors Sort By. Snapshot field optional.

### 9. Preview pane
⌥⌘P toggles a trailing inspector column (fixed ~280 pt) on the tab: large preview (image/PDF via `PreviewRenderer`, others via `QLThumbnailGenerator`) + metadata block reusing `InfoGatherer` fields (kind, size, dates, tags). Follows the active pane's single selection; multi/empty selection shows count / placeholder. State on `TabState.showsPreviewPane`, snapshot-persisted (optional).

### 10. Share menu (incl. AirDrop)
Context-menu "Share…" opens `NSSharingServicePicker(items: selectedURLs)` anchored at the row via an `NSViewRepresentable` bridge holding a zero-size anchor view (posture of `QuickLookController`). No service filtering — the system list (AirDrop, Mail, Messages, …) as-is.

### 11. Put Back
Core `TrashRegistry` (`@Observable`-free, pure + a persister): records `original → trashed` URL pairs on every app trash op (hooked in `PaneState.trashSelected` alongside `UndoRecorder.recordTrash`), persisted to `trash-registry.json` (atomic, corrupt-file-safe like `SessionPersister`). Entries whose trashed file no longer exists are pruned on load/save. When a listed entry's URL is inside a directory named `.Trash`/`Trash` and has a registry record, the context menu shows "Put Back" → `FileOperationService.relocate(toExactly: original)` (existing collision guard applies), removing the record on success. Undo of Put Back re-trashes to the recorded trash URL.

### 12. Spring-loaded folders
Folder rows/cells already accepting drops gain spring-loading: while a drag hovers a folder row (`isTargeted == true`) a 700 ms timer runs; expiry navigates the pane into that folder (drag continues, drop then lands wherever the user releases). Leaving the row cancels the timer. A `SpringLoadModel` (owned per pane view, `@Observable`) holds the timer; the delay constant lives in Core so the trigger decision (`shouldSpring(hoverStart:now:)`) is unit-testable.

### 13. Tags in the sidebar
"Tags" sidebar section listing `NSWorkspace.shared.fileLabels` (standard tags, colored dots via the existing tag-color mapping in `TagDotsView`) plus any tags currently in `SettingsStore.knownTags` (new field, updated as listings surface tags). Clicking a tag applies `filter.tags = [tag]` to the active pane (same code path as the filter bar); clicking the active tag clears it.

### 14. Finder comments
`InfoGatherer` gains `finderComment: String?` (MDItem read). Get Info shows a "Comments" row with an editable text field; commit writes the `com.apple.metadata:kMDItemFinderComment` xattr (binary plist, `TagWriter` pattern) via new `CommentWriter`. Write failures surface in the status bar (tag-failure posture).

---

## Testing

TDD against the executable harness (`swift run FileExplorerTests`). Unit-testable in Core: `GridNavigator` neighbor picking (crafted frame grids incl. ragged last row), symlink creation + collision naming + undo, sort-menu comparator round-trip, `Grouper` all four axes + bucket edges, `TrashRegistry` record/prune/round-trip/corrupt-file recovery, spring-load trigger timing decision, comment plist encode/decode, new-folder-with-selection planning (name + move set), snapshot backward-compatibility (v3 JSON fixtures still decode; new fields default).

MANUAL walkthrough: grid arrow keys incl. ⇧-extension, real USB eject, Recents/Tags sidebar interactions, Share sheet + AirDrop, preview pane rendering + toggle persistence, spring-loaded drag, Put Back on a real Trash item, Finder comment visible in Finder after reindex, Sort By/Group By menus in all three views.

## Error handling

Eject failure, put-back collision ("original location occupied"), comment/tag write failure, and partial new-folder-with-selection moves all land in the status bar (existing aggregate posture). Trash-registry corruption → silently start empty (persister posture). Free-space fetch failure → hide the label. Spring-load never fires after the drag ends (timer cancelled on `isTargeted == false`).

## Out of scope (v4)

Gallery view, per-folder view options, permissions editing, iCloud awareness, Connect to Server, Services menu, themes, smart folders (filter presets already cover the folder-scoped case), configurable spring-load delay/recents cap.

## Build order

M13 → M14, one branch + plan doc each (`v4.0-m13`, `v4.0-m14`), matching the v1–v3 process. Within M13: items 4, 6, 5, 3, 2, 7, 1 (pure-Core-first). Within M14: 8, 11, 14, 13, 9, 10, 12. Version bumps: 3.1.0 after M13, 4.0.0 after M14.
