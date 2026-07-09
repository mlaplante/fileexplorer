# Disk Usage Analyzer + Duplicate Finder — Design

**Date:** 2026-07-09
**Status:** Approved (user directive: continue autonomously, delegate implementation to Codex)

## Problem

"What is eating my disk?" and "which of these files are copies?" both force a
round-trip to a separate app (DaisyDisk, Gemini). The primitives already
exist in Core (`FolderSizer`, `FileHasher`) but nothing composes them into
answers.

## Goal

- **Analyze Disk Usage** on the current folder (Tools menu / palette /
  folder context menu): a sheet showing the folder's children ranked by
  recursive size with proportion bars, drill-down navigation, and actions
  (Reveal in pane, Move to Trash) — live-updating totals as the scan runs.
- **Find Duplicates** on the current folder: a sheet listing groups of
  byte-identical files (size pre-filter + SHA-256 confirm), with per-group
  keep-strategy selection (keep newest / oldest / per-file checkboxes) and
  Trash of the rest through the existing undo-able operation path.
- Both cancel cleanly, skip unreadable entries silently, and never block
  the main actor.

## Approach (chosen): incremental scanner actors + pure ranking/grouping

Two Core engines, each an incremental async scan publishing progress:

- `UsageScanner`: one recursive `FileManager` enumeration of the root
  (single pass, drop-on-failure) accumulating per-immediate-child byte
  totals + item counts; publishes running totals every ~200 entries so the
  sheet fills in live. Drill-down = new scan rooted at the child (results
  cached per path for the sheet's lifetime).
- `DuplicateFinder`: stage 1 groups regular files by exact size (skip 0-byte
  and symlinks); stage 2 hashes only size-colliding files via `FileHasher`;
  groups with ≥2 identical hashes are duplicates. Pure decision helpers
  (`DuplicateKeepPlanner`) compute which URLs a keep-strategy trashes.

**Rejected:** treemap visualization (large custom-drawing effort; ranked
bars answer the question); content-defined chunking or partial-hash
heuristics (SHA-256 after a size filter is already cheap enough at folder
scope); Spotlight size queries (stale and permission-fuzzy).

## Semantics decisions

- **Scope:** both tools operate on the active pane's current folder,
  recursively. No volume-wide mode (YAGNI; navigate to `/` if you mean it).
- **Usage rows:** immediate children of the scanned root, sorted by size
  descending; each row shows name, human size (existing byte formatter —
  reuse whatever the status bar uses), item count, and a proportion bar
  scaled to the largest child (not the total — keeps small rows readable).
  Files and folders both rank (files are leaf rows, no drill-down). Hidden
  entries included (that's where the bytes hide). Symlinks not followed.
- **Drill-down:** clicking a folder row re-roots the sheet (breadcrumb of
  scanned ancestors for backing out; "Reveal in pane" navigates the active
  pane to the row's parent and selects it, closing the sheet).
- **Usage actions:** Move to Trash routes through the same PaneState trash
  path as pane rows (undo + Put Back registry apply); the affected row's
  bytes are subtracted immediately.
- **Duplicate grouping:** key = (size, sha256). Groups sorted by wasted
  bytes descending (size × (count−1)). Within a group rows sorted by
  modified date descending, showing path relative to the scan root, size,
  modified. Hash failures drop the file from consideration silently.
- **Keep strategies:** per group segmented control — Keep newest (default),
  Keep oldest, Custom (checkboxes; at least one must stay checked — the
  planner refuses plans that trash every copy). "Trash selected" executes
  across all groups in one undo-able batch.
- **Cancellation:** closing either sheet cancels the underlying scan Task;
  results are keyed by a generation so a stale scan can't repopulate a
  reopened sheet.
- **Limits:** scans cap at 250k entries (usage) / 100k files (duplicates);
  hitting the cap shows a "partial results" note in the sheet footer —
  never a silent truncation.

## Components

| Unit | Kind | Responsibility |
|---|---|---|
| `UsageScanner` (new, Core) | @MainActor @Observable | incremental child-total accumulation, per-path cache, cancel, cap |
| `UsageRow` / ranking (new, Core, pure) | struct + enum | (child totals) → sorted rows with proportions; byte subtraction on trash |
| `DuplicateFinder` (new, Core) | @MainActor @Observable | two-stage scan (size → hash), progress, cancel, cap |
| `DuplicateKeepPlanner` (new, Core) | pure enum | (groups, strategy/selection) → URLs to trash; refuses empty-keep groups |
| `UsageSheet` (new, app) | SwiftUI | ranked bars, breadcrumb drill-down, actions |
| `DuplicatesSheet` (new, app) | SwiftUI | groups, keep strategies, batch trash |
| `FileExplorerApp` / `FileActionsMenu` / `PaletteCoordinator` (modify) | SwiftUI | Tools-menu commands, folder context items, palette entries |

## Testing

Executable harness, real temp trees:
- `UsageScannerTests`: sizes attribute to the right immediate child across
  nesting; files rank as leaves; unreadable subdir skipped; cancellation
  stops publication; cap marks partial; cache serves re-rooted scans;
  trash subtraction math.
- `UsageRankingTests` (pure): sort order, proportion scaling to max child,
  zero-byte root, tie-break by name.
- `DuplicateFinderTests`: identical twins found; same-size-different-bytes
  not grouped; 0-byte and symlinks skipped; three-way group wasted-bytes
  ordering; unreadable file dropped silently; cancel; cap partial flag.
- `DuplicateKeepPlannerTests` (pure): newest/oldest keep math on fixture
  dates; custom selection; all-unchecked group → refused (returns nil /
  keeps group untouched); cross-group batch aggregation.
- Integration: planner output through the existing trash path leaves the
  kept file on disk and the trashed ones registered for Put Back.
