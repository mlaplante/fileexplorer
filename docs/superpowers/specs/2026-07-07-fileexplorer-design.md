# FileExplorer — Design Spec

**Date:** 2026-07-07
**Status:** Approved
**Goal:** A personal-use native macOS file manager cloning the feature set of WhimFiles (https://whimfiles.com/): filter-centric browsing, dual panes, tabs, fuzzy navigation, previews, and batch file tools.

## Decisions

- **Platform:** Native macOS, SwiftUI, Swift 6, macOS 15+ deployment target, Apple Silicon.
- **Architecture:** Pure SwiftUI (approach A). AppKit bridges only where SwiftUI cannot do the job: `QLPreviewPanel` (Quick Look) and low-level key handling. If very large directories (100k+ entries) ever stutter, retrofit an `NSTableView` wrapper for the list view only.
- **Scope:** Faithful clone of WhimFiles features; no additions in v1.
- **Distribution:** Local build only — no App Store, no sandbox. The app requires Full Disk Access, granted once in System Settings.
- **Project format:** Swift Package (SPM) — this machine has Command Line Tools only (no Xcode, so no `xcodebuild`; verified 2026-07-07). `swift build` compiles SwiftUI fine; a `Scripts/bundle.sh` assembles `FileExplorer.app` with an ad-hoc codesign.
- **Testing runtime:** CLT ships neither XCTest nor Swift Testing runtimes (verified — `swift test` fails at dlopen). Tests are a plain executable target (`swift run FileExplorerTests`) with a minimal assert harness that exits non-zero on failure. Core logic is pure functions, so this covers what matters.

## Feature Set (from WhimFiles)

1. **Filtering:** real-time, composable filters by type preset (Images, PDFs, Videos, Documents), custom extension list, date range, and size range — all applicable simultaneously.
2. **Dual pane:** two independent folder views per window, each with its own history, filters, and search; file operations between panes.
3. **Navigation:** fuzzy folder jump (⌘G), fuzzy file finder (⌘P), sidebar with bookmarks and mounted volumes, breadcrumb path bar, hidden-file toggle.
4. **Tabs:** multiple in-window tabs, each remembering layout, filters, and folder state; keyboard shortcuts to switch.
5. **Previews:** Quick Look with arrow-key navigation, hover previews for images and PDFs, thumbnail (icon) view mode.
6. **File tools:** batch rename (find & replace, sequential numbering, prefix/suffix) with live preview; image conversion (HEIC/WebP/AVIF → JPG/PNG); ZIP compression; undo for moves and deletions.
7. **Extras:** command palette (⇧⌘A), on-demand folder size calculation, terminal integration (shell function to open the app at a path).

## Architecture

### State model (all `@Observable`)

- **`PaneState`** — one per pane: current folder URL, back/forward history stacks, sort descriptor, active `FilterState`, selection set, in-pane search text, view mode (list/icons).
- **`TabState`** — one or two `PaneState`s, active-pane index, layout (single/dual).
- **`AppState`** — open tabs, active tab, sidebar bookmarks, preferences. Persisted as JSON in `~/Library/Application Support/FileExplorer/`.

### Directory loading & watching

- `DirectoryLoader` enumerates a folder off the main actor via `FileManager`, producing `[FileEntry]` — a value struct: URL, name, size, created/modified dates, `UTType`, `isDirectory`, `isHidden`, `isSymlink`.
- **Symlink semantics (Finder-like):** a symlink whose target is a directory has `isDirectory == true` (double-click navigates into it, `kind` shows Folder); `isSymlink` stays true so the UI can badge it. Per-entry attribute failures are dropped from listings by design (TOCTOU races); this is documented on `DirectoryLoader.load`.
- Each pane owns a `DirectoryWatcher`: a `DispatchSource.makeFileSystemObjectSource` on the open directory file descriptor; reloads on write events, debounced (~200 ms).
- Sorting and filtering are applied in-memory on the loaded entries; the Table renders the filtered array.

### Filtering & fuzzy search

- **`FilterEngine`** — pure function `apply(filters: FilterState, to: [FileEntry]) -> [FileEntry]`. `FilterState` holds: optional type preset (mapped to `UTType` conformance checks), custom extension set, optional date range (modified), optional size range. Fully unit-testable.
- **`FuzzyMatcher`** — pure subsequence scorer (prefers word-boundary and consecutive matches), shared by:
  - **⌘G folder jump:** candidates = bookmarks + recent folders + subfolders of the current folder (bounded-depth background scan, capped).
  - **⌘P file finder:** background recursive enumeration under the current folder, capped (e.g. 50k entries), streamed into the results list.
  - **⇧⌘A command palette:** static registry of `Command` values (name, shortcut, action closure, enablement predicate).

### File operations & undo

- **`FileOperationService`** — move, copy, rename, trash, new folder; used by menus, drag & drop, and cross-pane shortcuts. All ops run off-main and report progress/errors.
- **Batch rename:** a pure `RenamePlan` engine computes before→after pairs from rules (find/replace, sequential numbering with padding/start, prefix/suffix); UI shows the live preview; conflicts (duplicate targets, existing files) are flagged before commit. Unit-testable.
- **Image conversion:** ImageIO (`CGImageSource` → `CGImageDestination`) for HEIC/WebP/AVIF → JPG/PNG, with quality option for JPG. Runs as a batch with per-file error reporting.
- **ZIP:** compress selection via `Process` running `/usr/bin/zip` (simple, handles folders) — revisit Apple Archive if shelling out proves limiting.
- **Undo:** window-level `UndoManager`. Move registers the inverse move; trash records the returned trash URL and restores from it. Copy/new-folder register delete-as-undo. Conversions and ZIP are not undoable (they create new files; delete manually).

### Previews

- **Quick Look:** `QLPreviewPanel` driven through an AppKit responder bridge; space toggles, arrow keys move selection while the panel follows.
- **Hover preview:** after ~500 ms hover on an image/PDF row, a popover shows a downsampled render (ImageIO thumbnail; PDFKit first page). Dismisses on mouse-out.
- **Thumbnail mode:** grid view using `QLThumbnailGenerator`, thumbnails cached in-memory (NSCache) keyed by URL + mtime.

### UI layout

- `NavigationSplitView`: **sidebar** (bookmarks section, volumes section via `mountedVolumeURLs`) → **content**.
- Content stack, top to bottom: custom in-window **tab bar** → **breadcrumb path bar** (clickable segments) → **filter bar** (preset chips + date/size/extension popovers) → **file `Table`** (name, size, kind, date modified; sortable, resizable) or thumbnail grid → **status bar** (item/selection counts, on-demand folder size).
- **Dual pane:** `HSplitView` of two pane views. The active pane is visually highlighted; all shortcuts and menu actions target it. A "move/copy to other pane" command operates between them.
- Keyboard: ⌘G/⌘P/⇧⌘A as above, ⌘T new tab, ⌘W close tab, ⌘1–9 switch tab, ⌘⇧. toggle hidden files, ⌘⌫ trash, Enter rename, ⌘O / ⌘↓ open, ⌘↑ parent folder.

### Error handling

- File-op failures show a non-blocking banner with the failing file and underlying `NSError` message; batch ops aggregate failures into one report.
- Missing permissions (EPERM on protected folders) show a hint linking to the Full Disk Access pane.
- A watched folder disappearing navigates the pane to the nearest existing ancestor.

## Testing

- **Unit tests (executable harness, `swift run FileExplorerTests`):** `FilterEngine`, `FuzzyMatcher`, `RenamePlan` (pure logic); `FileOperationService` and undo against temp directories; `DirectoryLoader` attribute correctness.
- **Manual verification:** run the app after each build-order milestone and exercise the new feature end-to-end.

## Build Order

Each milestone leaves a working, usable app:

1. **Browse:** app shell, sidebar, single pane, Table, navigation (breadcrumbs, history, keyboard), hidden-file toggle, live folder watching.
2. **Filter:** filter bar, FilterEngine, presets + custom extension + date + size.
3. **Panes & tabs:** dual pane, active-pane model, in-window tabs with state memory.
4. **Find:** fuzzy matcher, ⌘G, ⌘P, ⇧⌘A command palette.
5. **Preview:** Quick Look, hover previews, thumbnail mode.
6. **Tools:** file ops + drag & drop + undo, batch rename, image conversion, ZIP, folder size, terminal shell function.

## Out of Scope (v1)

- App Store distribution, code signing beyond local, auto-update.
- Cloud storage integrations, network volumes beyond what mounts in Finder.
- Custom themes; Finder-style column view; file content search (name-only).
