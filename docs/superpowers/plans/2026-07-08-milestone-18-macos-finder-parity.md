# Milestone 18 — macOS Finder Parity

**Goal:** Close the remaining platform-integration gaps users expect from a
Finder replacement.

## Scope

- Connect to Server for SMB/WebDAV/NFS URLs and mounted-server shortcuts.
- Services and Quick Actions integration from selection context menus.
- Package browsing toggle: Open vs Show Package Contents for bundle-like
  directories.
- Real Finder alias-file creation in addition to the current symlink aliases.
- Disk image tools: create DMG, mount, unmount, and verify checksums.

## Implementation Notes

- Prefer AppKit/Foundation APIs where available; shell out only for platform
  features without stable public APIs.
- Keep symlink alias behavior available because it is transparent and useful.
- Platform panels and Services need manual walkthrough coverage because they
  are difficult to automate under TCC.

## Test Focus

- URL normalization for server connections.
- Package detection and command availability.
- Alias mode selection and collision naming.
- Disk image command planning where actual mounting is manual.

