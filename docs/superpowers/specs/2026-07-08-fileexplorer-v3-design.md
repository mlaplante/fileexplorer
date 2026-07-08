# FileExplorer v3 — Design Spec

**Date:** 2026-07-08
**Status:** Approved
**Scope:** Close the daily-driver gaps against Finder, make search content-aware, exploit the dual-pane layout, and pay off platform polish (settings UI, icon, updates). Four milestones (M9–M12), each leaving a working app, continuing the v1/v2 cadence.

## Approved decisions

1. **v3 covers five clusters:** daily-driver parity, search & filters, dual-pane power tools, platform & polish, and app-icon generation.
2. **Content search = Spotlight + fallback:** `NSMetadataQuery` first, manual streaming scan for unindexed scopes.
3. **Updates = GitHub release check:** notify + link to the release page. No Sparkle, no signing infrastructure (app stays ad-hoc signed).
4. **Icon generated in-repo:** drawn in code (CoreGraphics), rendered to `.icns` by script. No external assets.
5. **Folder compare ships with one-way sync:** diff view plus a previewed, undoable "make other pane match" copy action. No two-way merge.

## Constraints (unchanged from v1/v2)

CLT-only toolchain: no `xcodebuild`, no `swift test`, no `@State`/`@FocusState` (use `@Observable`/`@Bindable`). Tests run via the executable harness (`swift run FileExplorerTests`). TCC blocks agent-driven UI automation, so gesture/panel behaviors land on the manual walkthrough list.

---

## Milestone 9 — Daily-driver ops + app icon

### Clipboard file operations
- **⌘C** writes the selection's file URLs to `NSPasteboard.general` (standard `public.file-url` types, so copy/paste interoperates with Finder).
- **⌘V** pastes into the active pane's folder as a **copy**; **⌥⌘V** pastes as a **move** (Finder parity). Both route through `FileOperationService` and register undo (delete-as-undo for copy, inverse move for move).
- Cross-app: pasting URLs copied from Finder works; copying in FileExplorer and pasting in Finder works.

### Duplicate and New File
- **⌘D Duplicate:** copies each selected item next to itself using Finder-style collision naming (`name copy`, `name copy 2`, …).
- **⌥⌘N New File:** creates an empty file in the active pane (name prompt like New Folder); same collision naming.
- The collision-naming logic is one pure function in Core (`collisionFreeName(_:existing:)`), shared by both, unit-tested.

### Copy Path
Context-menu items: POSIX path and `~`-abbreviated path, written to the general pasteboard as strings.

### Open With
Context submenu listing applications from `NSWorkspace.shared.urlsForApplications(toOpen:)` for the selected file's URL (single-selection; multi-selection uses the first item's type). Opens via `NSWorkspace.open(_:withApplicationAt:configuration:)`.

### Archive extraction
- Detection by `UTType` (zip, gzip, tar and tar variants).
- Extraction via `Process`: `ditto -x -k` for zip, `tar -xf` for tarballs — same shell-out posture as v1's ZIP compression.
- Output lands in a collision-suffixed sibling folder named after the archive; the created folder registers delete-as-undo (same pattern as copy/new-folder).
- Per-file/per-archive failures aggregate into the existing status-bar error report.

### Get Info panel
- Read-only inspector (separate panel window, `@Observable` model): name, kind, size (on-demand calculation for folders, reusing the existing folder-size machinery), created/modified dates, POSIX permissions string, owner/group, where-from (`kMDItemWhereFroms`), and symlink target when applicable.
- Follows the selection of the active pane; multi-selection shows count + aggregate size.
- SHA-256 display is added to this panel in M11 (checksums arrive there).

### App icon
- New SPM executable target **`IconGen`**: draws the icon (dual-pane motif) with CoreGraphics and writes a 1024×1024 PNG.
- **`Scripts/make-icon.sh`**: runs `IconGen`, produces the size ladder with `sips`, assembles `FileExplorer.icns` with `iconutil`. Output is committed to `Resources/` so `bundle.sh` doesn't depend on regeneration.
- `Resources/Info.plist` gains `CFBundleIconFile`; `bundle.sh` copies the `.icns` into `Contents/Resources/`.

## Milestone 10 — Search & filters

### File content search
- New palette **Search File Contents** (shortcut ⇧⌘F), scoped to the active pane's folder subtree.
- **Primary engine:** `NSMetadataQuery` with `kMDItemTextContent CONTAINS[cd] term`, scope set to the pane folder; results stream into the palette list as they arrive.
- **Fallback engine:** Core `ContentScanner` — recursive enumeration (bounded like ⌘P's 50k cap), filtering to text-like `UTType`s under a size cap (default 2 MB), streaming each file through a pure substring matcher. Used automatically when the scope is unindexed (query returns zero results *and* the volume/folder reports no Spotlight indexing) and available on demand via a palette row ("Deep scan…").
- The matcher and the text-likeness/size gate are pure Core functions, unit-tested; `NSMetadataQuery` wiring is manual-walkthrough.
- Selecting a result navigates the pane to the containing folder and selects the file (same behavior as ⌘P).

### Saved filter presets
- "Save Filter Preset…" (filter bar + command palette) names the pane's current `FilterState`; presets persist in `SettingsStore` (`[FilterPreset]`, Codable: name + FilterState).
- Recall from a new **Presets** sidebar section and from the command palette ("Apply Preset: <name>"). Applying replaces the active pane's `FilterState`. Delete via context menu on the sidebar row.
- `FilterState` is already Codable (M7), so the preset codec is round-trip tested for free.

### Finder tags
- `FileEntry` gains `tags: [String]` read from `URLResourceValues.tagNames` during `DirectoryLoader.load` (cost is one more resource key in the existing batch fetch).
- **Display:** colored dot badges (standard Finder tag colors by name; unknown tags get gray) in table rows and grid cells.
- **Assign/remove:** context submenu listing the standard label names (`NSWorkspace.shared.fileLabels`) plus tags seen in the current listing, plus free-text entry; writes via `URLResourceValues`.
- **Filter:** `FilterState` gains an optional tag set (entry matches if it has *any* selected tag), joining the existing composable dimensions and persisting with sessions. Optional field → M7/M8 `session.json` files still decode.

## Milestone 11 — Dual-pane power tools

### Folder compare + one-way sync
- **`FolderComparator`** (Core, pure): given two rooted listings (relative path → size + mtime), classifies entries as `onlyLeft`, `onlyRight`, or `differs` (size mismatch, or mtime differing beyond a 2 s FAT-tolerance). Recursion bounded by depth/entry caps matching ⌘P's; hidden files respected per pane setting.
- **Compare mode** (command palette + Panes menu, dual-pane only): both panes badge rows by classification (color + symbol); a banner shows summary counts and holds the actions.
- **Sync action** ("Copy Differences to Other Pane", direction explicit in label): preview sheet lists exactly the planned copies (only-source + differs entries, overwrites flagged); commit routes through `FileOperationService` with undo (copies register delete-as-undo; overwrites register restore-from-trash). Nothing is ever deleted from the target beyond explicit overwrites.

### Batch-rename tokens
`RenamePlan` rules extended (all pure; metadata injected):
- **Regex find/replace** (`NSRegularExpression` syntax, capture-group references in the replacement); invalid patterns surface as a validation error in the live preview, never a crash.
- **Case transforms:** upper / lower / title on the name stem.
- **Date tokens:** `{modified:yyyy-MM-dd}` and `{exif:yyyy-MM-dd}` (EXIF capture date via ImageIO, falling back to modified date when absent). The planner receives a `[URL: Metadata]` map so planning stays pure and testable.

### Conversions & checksums
- **Image resize:** context submenu presets (25%, 50%, longest-edge 1024/2048 px), ImageIO downsampling, output as sibling with suffix (`name@1024.jpg` style), outputs selected after reload (M8 pattern).
- **PNG→WebP:** included **only if** `CGImageDestination` supports WebP encode on macOS 15 (verified during implementation); if not, the item is dropped from the menu — no third-party encoder shim.
- **Checksums:** streaming SHA-256 (CryptoKit) — "Copy SHA-256" context item and a row in Get Info (computed on demand, off-main, cancellable).

## Milestone 12 — Platform & polish

### Settings window
SwiftUI `Settings` scene (works under SPM): **General** (JPG quality, update-check toggle) and **Shortcuts** (below). `SettingsStore` is already the persistence home.

### Column view
Third view mode (⌥⌘3): horizontal `ScrollView` of list columns driven by the pane's current path; selecting a folder in column *n* populates column *n+1*; selecting a file shows a lightweight info/preview column. Reuses `DirectoryLoader` + existing row rendering; keyboard ←/→ move between columns, ↑/↓ within.

### Rubber-band grid selection
Drag on empty grid space draws a selection rectangle; cells intersecting it become the selection (⇧ extends, ⌘ toggles). View-layer geometry only — selection state stays on `PaneState`.

### Shortcut customization
- The command registry (palette `Command` values) becomes the single shortcut source; menus and key handling read from it.
- `SettingsStore` gains `shortcutOverrides: [commandID: KeyChord]`. The Shortcuts settings pane lists commands with a record button (local `NSEvent` monitor captures the chord — no `@FocusState` needed). Conflicts are flagged inline; a Reset restores defaults.
- Pure pieces (chord encode/decode, conflict detection, override merge) are unit-tested.

### Update check
- At most once per day (timestamp in `SettingsStore`, toggleable off): fetch `https://api.github.com/repos/mlaplante/fileexplorer/releases/latest`, compare `tag_name` against `CFBundleShortVersionString` with a pure semver comparator.
- Newer version → non-blocking banner with "View Release" opening the release page in the browser. Network or parse failures are silent (logged only).

---

## Testing

TDD against the executable harness. Unit-testable in Core: collision naming, archive-type detection, content-scanner matcher + text-likeness gate, filter-preset round-trip, tag filtering, `FolderComparator` classification, rename regex/case/date-token planning (with injected metadata), semver comparison, shortcut chord codec + conflict detection.

MANUAL walkthrough: pasteboard interop with Finder, Open With submenu, Get Info panel, `NSMetadataQuery` streaming, tag writes visible in Finder, compare-mode badges + sync preview sheet, resize/WebP outputs, Settings window, column-view keyboard flow, rubber-band gesture, update banner (point the check at a fixture release).

## Error handling

- Extraction and sync failures aggregate into the existing status-bar error report; partial completion leaves completed items in place (same posture as batch ops).
- Invalid regex in batch rename is a preview-time validation error; commit is disabled while invalid.
- Spotlight unavailability degrades to the fallback scanner, never an error dialog.
- Update-check failures are invisible to the user.
- Tag write failures (read-only volumes) surface per-file in the status bar.

## Out of scope (v3)

App Store distribution and real code signing, Sparkle-style in-app updating, cloud storage integrations, custom themes, two-way folder sync/merge, file content *indexing* of our own (we only query Spotlight or scan on demand), editable permissions in Get Info, multi-frame image conversion beyond frame 0.

## Build order

M9 → M10 → M11 → M12, one branch + plan doc each, matching the v1/v2 process. No hard dependencies between milestones beyond `SettingsStore` fields, which already exist; order is by daily-use value.
