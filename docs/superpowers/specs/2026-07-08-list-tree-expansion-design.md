# List-View Tree Expansion (Finder-style disclosure) — Design

**Date:** 2026-07-08
**Status:** Approved (user directive: plan autonomously, delegate implementation to Codex)

## Problem

Navigating into a folder replaces the whole listing — you lose your place in
the parent. Finder's list view solves this with disclosure triangles: a folder
expands inline, indented one level, without navigating away.

## Goal

Finder-parity tree expansion in the **list view only** (grid, columns, and
grouped list are unaffected):

- Chevron on every folder row; click toggles expansion, ⌥-click expands the
  whole subtree.
- `→` expands selected collapsed folders (⌥`→` recursive); `←` collapses
  selected expanded folders, or jumps a single nested selection to its parent
  row.
- Children render indented below their folder, live-updating (watched), with
  the pane's filter and sort applied **per level**.
- Expansion state survives quit/relaunch via session persistence.
- Everything that works on a top-level row keeps working on a nested row:
  selection (incl. ⇧-ranges), drag, drop-into-folder, spring-loading, hover
  preview, context menu, Quick Look, folder sizes, compare badges.

## Approach (chosen): flattened rows + pure Core flattener

Keep the existing `Table(of: FileEntry.self)` and its flat `visibleEntries`
array. A new pure `TreeFlattener` in FileExplorerCore turns
(root entries, loaded-children cache, expanded set, per-level filter+sort)
into an ordered `[(FileEntry, depth)]`. `PaneState` owns the expansion state
(`expandedFolders: Set<URL>`), a raw children cache (`childEntries`), and one
`DirectoryWatcher` per expanded folder. The Name cell gains a rotating chevron
and depth-proportional leading padding.

**Rejected:** SwiftUI `DisclosureTableRow`/`OutlineGroup`. It wants
binding-driven recursive row builders (@State-shaped — this CLT-only
toolchain cannot compile `@State`), bypasses the existing
FilterEngine/FileSorter pipeline and `sortOrder: [KeyPathComparator<FileEntry>]`
machinery, and is untestable under the executable-harness constraint. The
flattened approach keeps the row type `FileEntry`, so every existing row
feature and the sort/session plumbing work unchanged.

## Semantics decisions

- **Expansion keys are standardized URLs** (matches `folderSizes` precedent).
- **Lazy loading:** children load on first expand (detached
  `DirectoryLoader.load`, same pattern as `reload()`). An expanded folder
  whose load hasn't landed renders collapsed until it does. Unreadable or
  vanished folders silently drop their expansion.
- **Collapse keeps descendant expansion state** (Finder behavior: re-expanding
  a parent restores the subtree). Selected rows hidden by a collapse are
  deselected and replaced by selecting the collapsed folder — an invisible
  selection must never feed file operations.
- **Filter and sort apply per level.** A filtered-out folder can't show
  children (its row is gone). Sort-column clicks re-sort every level.
- **Grouped mode (`groupBy != .none`) disables the tree** — chevrons hidden,
  flattener bypassed (Finder also has no disclosure while grouped). Grid and
  columns views always see root-level `visibleEntries` (flattening is gated
  on `viewMode == .list`).
- **Status bar counts top-level items only** — disclosure must not inflate
  "N items".
- **Cycle/runaway guards:** flattener refuses to recurse into a
  symlink-resolved path already on its ancestor stack and caps depth at 32;
  recursive expand caps at 512 folders.
- **Live updates:** each expanded folder gets its own `DirectoryWatcher`
  (kqueue fd per folder — bounded by how many the user expands, cleared on
  navigation). Pane `reload()` also refreshes all expanded folders' children
  and prunes vanished ones.
- **Persistence:** `SessionSnapshot.Pane` gains optional `expandedFolders:
  [String]` (decodeIfPresent — old session.json files and old builds reading
  new files both keep working, per the FilterState precedent). Restored
  expansions reload their children on first `reload()`.
- **Double-click on a folder still navigates into it** (unchanged); the
  chevron is the only expand affordance besides `→`.

## Components

| Unit | Kind | Responsibility |
|---|---|---|
| `TreeFlattener` (new, Core) | pure enum | flatten(roots, children, expanded, prepare) → depth-annotated rows; cycle + depth guards |
| `PaneState` (modify) | @Observable | expansion state, child loading/watching, expansion-aware `recomputeVisible()`, selection hygiene, snapshot fields |
| `SessionSnapshot.Pane` (modify) | Codable | optional `expandedFolders` round-trip |
| `PaneView` (modify) | SwiftUI | chevron + indent in Name cell, `←`/`→` key handling, root-count status bar, `entries` → `visibleEntries` lookups for row actions |
| `PreviewPaneView`, `FileActionsMenu` (modify) | SwiftUI | act-on-row lookups switch to `visibleEntries` so nested rows work |

## Testing

Executable harness (`swift run FileExplorerTests`), no UI tests possible:
- `TreeFlattenerTests`: ordering/depths, per-level prepare, missing-cache =
  collapsed, hidden-descendant expansion preserved across parent collapse,
  cycle guard, depth cap.
- `PaneState` tree tests against real temp directories: expand/collapse
  round-trip, per-level sort, collapse selection hygiene, reload pruning of
  vanished folders, recursive expand, snapshot round-trip + legacy decode.

Manual walkthrough items (chevron hit-target feel, ⌥-click, spring-load onto
nested rows, live-update of an expanded subfolder) join the pending M9+ list.
