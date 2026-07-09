# Archive Browsing — Design

**Date:** 2026-07-09
**Status:** Approved (user directive: continue autonomously, delegate implementation to Codex)

## Problem

Peeking inside a zip today means extracting the whole thing next to the
archive (Unarchiver) and cleaning up after. Path Finder and ForkLift let you
look inside without paying for extraction; FileExplorer should too.

## Goal

A read-only **archive browser sheet**: "Browse Archive…" on any supported
archive (zip + the tarball family `ArchiveKind` already detects) opens a
navigable listing — folders, files, sizes, dates — with Quick Look on files,
selective **Extract Selected…** into a chosen folder, and **Extract All**
(existing Unarchiver behavior). No writes into archives, ever.

## Approach (chosen): dedicated sheet over a listed catalog + on-demand single-entry extraction

A pure `ArchiveCatalogParser` turns `bsdtar -tvf` output (bsdtar reads both
zip and every tarball variant — one listing code path) into a virtual tree
(`ArchiveCatalog`: entries with path, size, modified, isDirectory). An
`ArchiveBrowserModel` runs the listing subprocess off-actor, then serves
per-folder views by pure lookup. Opening/Quick-Looking a file extracts just
that entry to a session temp dir (`bsdtar -xf archive --include <path>` /
zip equivalent) and hands the temp URL to the existing QuickLookController.
Extract Selected re-uses the same single/multi-entry extraction into a
user-picked destination through the normal collision naming.

**Rejected:** in-pane virtual filesystem (PaneState/watchers/file-ops all
assume a real filesystem — threading a virtual FS through them touches
everything for one feature; a sheet delivers the value at a fraction of the
risk); libarchive bindings (new dependency; the CLI is already the proven
posture in Unarchiver); Archive Utility handoff (that's just extraction).

## Semantics decisions

- **Entry points:** context menu "Browse Archive…" on a single selected
  archive; also ⌘-double-click? No — keep double-click behavior unchanged
  (navigate/open); the context menu and File menu (enabled when the
  selection is one archive) are the affordances. Palette command included.
- **Listing:** one `bsdtar -tvf` run per archive open (`/usr/bin/tar` is
  bsdtar on macOS; it auto-detects zip + compression). Parse `ls -l`-style
  lines: mode, size, date, path; `d`-mode or trailing `/` → directory.
  Implicit parent directories (zips often omit them) are synthesized.
  Listing errors (encrypted, corrupt, unsupported) → alert with stderr
  excerpt; the sheet never opens empty.
- **Encrypted zips:** not supported in v1 — the listing succeeds but
  extraction fails; surface the extraction error as-is. (bsdtar lists
  encrypted entries fine; extracting reports the failure.)
- **Navigation:** breadcrumb + folder rows (double-click or Return enters,
  ⌘↑ goes up); list shows name, size (files), modified. Type-select works
  via plain List behavior; no filtering/sorting beyond name-sorted folders
  first (YAGNI).
- **Quick Look / Open:** selecting a file and hitting Space extracts that
  single entry to `NSTemporaryDirectory()/FileExplorer-ArchivePreview/<uuid>/`
  and Quick Looks it. "Open" (⌘O / double-click on a file) extracts the same
  way then `NSWorkspace.open`. Temp extraction is capped at 512 MB per
  entry — beyond that, an alert suggests Extract Selected instead. The
  preview temp root is deleted when the sheet closes.
- **Extract Selected…:** NSOpenPanel folder pick, then extract the selected
  entries (files and/or folders, recursive) preserving their relative paths
  under the destination, collision-suffixed at the top level via
  `CollisionNamer` (matching Unarchiver's naming posture). Runs off-actor
  with a progress spinner; errors alert with stderr excerpt.
- **Extract All:** delegates to the existing `Unarchiver.extract` (same
  next-to-archive destination + naming as today's behavior).
- **Security:** extraction always into a freshly created destination;
  entry paths are sanitized — absolute paths and `..` components are
  rejected by the catalog parser (dropped with a `hadSuspiciousPaths` flag
  surfaced as a footnote) so a hostile archive cannot escape the target
  (bsdtar also guards, but the catalog must not display them as navigable).
- **Size cap:** catalogs cap at 100k entries → "partial listing" footnote.

## Components

| Unit | Kind | Responsibility |
|---|---|---|
| `ArchiveCatalogParser` (new, Core) | pure enum | `tar -tvf` text → `[ArchiveEntry]`; implicit dirs; path sanitization; cap |
| `ArchiveCatalog` (new, Core) | pure struct | path-keyed tree: children(of:), entry lookup, entry count |
| `ArchiveExtractor` (new, Core) | enum, blocking | single/multi-entry extraction via bsdtar/ditto into a given destination; per-entry temp extraction |
| `ArchiveBrowserModel` (new, Core) | @MainActor @Observable | listing subprocess, current path, selection, temp-dir lifecycle, progress/error state |
| `ArchiveBrowserSheet` (new, app) | SwiftUI | listing UI, breadcrumb, Quick Look/Open, Extract buttons |
| `FileActionsMenu` / `FileExplorerApp` / `PaletteCoordinator` (modify) | SwiftUI | "Browse Archive…" entries |

## Testing

Executable harness; build real fixture archives in tests with `/usr/bin/zip`
(absent on some minimal setups — use `ditto -c -k` instead, which always
exists) and `/usr/bin/tar`:
- `ArchiveCatalogParserTests`: fixture `tar -tvf` lines (files, dirs,
  spaces in names, UTF-8), implicit parent synthesis, absolute/`..` path
  rejection + flag, cap.
- `ArchiveCatalogTests`: children(of:) ordering (folders first, name
  ascending), nested lookup, root listing.
- `ArchiveExtractorTests`: single-entry extraction from a ditto-built zip
  and a tar.gz round-trips bytes; multi-entry preserves relative paths;
  collision naming at destination; failure on a corrupt archive returns
  the stderr excerpt; temp-extraction helper lands under the given root.
- `ArchiveBrowserModelTests`: open real zip → catalog loads, navigation
  children correct; corrupt file → error state, sheet-open flag stays
  false; temp root removed on close.
