# FileExplorer

A personal, keyboard-driven macOS file manager: fast
dual-pane browsing, fuzzy palettes for navigation, commands, and
file-content search, previews, a Finder-style preview pane, saved filter presets, Finder tags,
batch tools (rename with regex & date tokens / convert / resize /
compress / extract), folder compare & sync, comments, Share, Put Back, checksums,
and full undo — built with Swift 6
and SwiftUI on top of Swift Package Manager.

## Finder power features

- Preview pane with metadata and large previews, toggled with `⌥⌘P`.
- Sort By and Group By menus for list and icon views.
- Finder-style inline folder expansion in list view, with per-level sort and filter.
- Share from the file context menu, including AirDrop through macOS sharing services.
- Open the active pane in a configured terminal or editor, and run user scripts against the selection.
- Git awareness in repo panes: colored read-only status dots, branch and changed count in the status bar, dimmed ignored files, and a Hide ignored filter toggle.
- Analyze Disk Usage from Tools, the command palette, or a folder context menu:
  scans the current folder recursively, ranks immediate children by size,
  supports drill-down, and caps scans at 250k entries with a partial-results note.
- Find Duplicates from the same entry points: scans the current folder
  recursively, groups byte-identical files by size + SHA-256, supports newest,
  oldest, or custom keep choices, and caps scans at 100k files with a
  partial-results note.
- Browse archives read-only from the context menu, Tools menu, or command
  palette: zip and tarball-family archives open in a sheet for navigation,
  Quick Look/Open of individual entries, Extract Selected, and Extract All.
  Encrypted zips may list but report the extraction failure when previewing or
  extracting.
- Disk usage and duplicate cleanup move files through FileExplorer's undo-able
  Trash path, so Undo and Put Back records apply.
- Put Back for items moved to Trash by FileExplorer.
- Tags and Recents in the sidebar, with tag clicks filtering the active pane.
- Finder comments in Get Info.

## Building

This project builds entirely with the Xcode **Command Line Tools** — no full
Xcode installation is required (and none of the code depends on Xcode-only
SwiftUI macro support, so `@State`/`@FocusState` are deliberately avoided in
favor of `@Observable`/`@Bindable`).

Build and assemble the app bundle:

```sh
./Scripts/bundle.sh
```

This runs a release build and produces `build/FileExplorer.app`, ad-hoc
code-signed and ready to launch.

For quick iteration without bundling:

```sh
swift build
swift run FileExplorer
```

## Testing

The test suite is a plain SPM executable (no XCTest bundle needed):

```sh
swift run FileExplorerTests
```

All assertions should report PASS.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T | New tab |
| ⌘W | Close tab |
| ⌘1 – ⌘9 | Jump to tab 1–9 |
| ⌘[ | Back |
| ⌘] | Forward |
| ⌘↑ | Enclosing folder (up) |
| ⇧⌘H | Go home |
| ⌘G | Go to Folder… (palette) |
| ⌘P | Find File… (palette) |
| ⇧⌘F | Search file contents (palette) |
| ⇧⌘A | Command Palette… |
| ⇧⌘. | Toggle hidden files |
| ⇧⌘D | Toggle dual pane |
| ⇧⌘K | Compare panes |
| ⌥⌘1 | View as List |
| ⌥⌘2 | View as Icons |
| ⌥⌘3 | View as Columns |
| View → Sort By | Sort by Name, Size, Kind, or Date Modified |
| View → Group By | Group by Kind, Date Modified, or Size |
| ⌥⌘P | Preview Pane |
| ⌘Y / Space | Quick Look |
| ⌘O / ⌘↓ | Open |
| ⌃⌘T | Open in Terminal |
| ⌃⌘E | Open in Editor |
| → / ⌥→ | Expand selected folder inline / expand entire subtree (list view) |
| ← | Collapse selected folder, or jump to parent row (list view) |
| ⇧⌘N | New folder |
| ⌥⌘N | New file |
| ⌘C / ⌘V | Copy / paste files (⌥⌘V moves) |
| ⌘D | Duplicate |
| Context menu | Make Alias |
| Context menu | Share…, Open in Terminal/Editor, Scripts, Put Back, Tags, and Finder comments via Get Info |
| ⌘I | Get Info |
| ⌘⌫ | Move to Trash |
| Return | Rename selected item |
| ⌘Z | Undo (⇧⌘Z to redo) |

Shortcuts for the character-key commands are customizable in Settings (⌘,)
→ Shortcuts. The app checks GitHub releases for updates once a day
(toggleable in Settings → General); it never auto-installs.

## Terminal helper (`fx`)

`Scripts/fx` opens FileExplorer at a given directory (or the current
directory if none is given):

```sh
fx            # open FileExplorer at $(pwd)
fx ~/Projects # open FileExplorer at ~/Projects
```

Install it on your `PATH`, e.g.:

```sh
ln -s "$(pwd)/Scripts/fx" /usr/local/bin/fx
```

**Caveat:** `open -a ... --args <path>` only passes the path argument on the
app's *first* launch (i.e. when no instance of FileExplorer is already
running). If FileExplorer is already open, `fx` will just bring the existing
window(s) forward without changing their location — quit the app first if you
need to force it to open at a specific path.

## Terminal, editor, and user scripts

Choose terminal and editor apps in Settings → Integrations. Open in Terminal
uses the single selected folder, or the pane folder otherwise. Open in Editor
uses the selection, or the pane folder when nothing is selected.

User scripts live in
`~/Library/Application Support/FileExplorer/Scripts`. Executable files in that
folder appear in File → Scripts, the file context menu, and the command palette.
Scripts run directly, with the pane folder as cwd. Selected paths are passed as
argv in selection order; when nothing is selected, the pane folder is passed as
the sole argument. Successful scripts show a transient banner, failures show an
alert with stderr, and the active pane reloads when the process exits.

## Git awareness walkthrough

For release checks, open a busy git repo and verify status dots match `git status`,
ignored entries are dimmed and hidden by Hide ignored, the status bar branch works
in normal repos and worktrees, and large repos stay responsive while status loads.

## Archive browsing walkthrough

For release checks, browse a large zip and a tar.gz from Browse Archive, verify
folder navigation remains responsive, preview an image or PDF via Quick Look,
extract selected nested files into a folder that already has a top-level name
collision, and verify corrupt or encrypted archives surface an error instead of
opening an empty browser.
