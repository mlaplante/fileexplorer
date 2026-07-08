# FileExplorer

A personal, keyboard-driven macOS file manager: fast
dual-pane browsing, fuzzy palettes for navigation, commands, and
file-content search, previews, saved filter presets, Finder tags,
batch tools (rename with regex & date tokens / convert / resize /
compress / extract), folder compare & sync, checksums, and full undo — built with Swift 6
and SwiftUI on top of Swift Package Manager.

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
| ⌘Y / Space | Quick Look |
| ⌘O / ⌘↓ | Open |
| ⇧⌘N | New folder |
| ⌥⌘N | New file |
| ⌘C / ⌘V | Copy / paste files (⌥⌘V moves) |
| ⌘D | Duplicate |
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
