# Locations Sidebar Section — Design

**Date:** 2026-07-08
**Status:** Approved

## Goal

Replace the sidebar's "Volumes" section with a Finder-style **"Locations"** section that shows everything Finder shows there: cloud storage accounts (Dropbox, OneDrive, Google Drive — any File Provider), iCloud Drive, the boot volume ("This Mac" entry), external/removable drives, and mounted network shares — each with a kind-appropriate icon, live-updating as things mount, unmount, or get installed.

## Why the current Volumes section misses cloud accounts

Dropbox/OneDrive on modern macOS are **File Provider** locations materialized under `~/Library/CloudStorage/<Provider-Account>/`, not mounted volumes — `FileManager.mountedVolumeURLs` never returns them. iCloud Drive lives at `~/Library/Mobile Documents/com~apple~CloudDocs`. On this machine today: `OneDrive-PFGVenturesLPdbaProformaInc` in CloudStorage, iCloud Drive present, "External SSD" in /Volumes.

## Approach (chosen)

Filesystem discovery: scan `~/Library/CloudStorage` for provider folders + a fixed iCloud Drive path, merged with `mountedVolumeURLs` classification. Rejected alternatives: `NSFileProviderManager` (needs entitlements/sandbox this SPM app doesn't have); hardcoded per-provider paths (brittle, doesn't cover future providers).

## Architecture

### Core (pure, testable): `LocationsBuilder`

New file `Sources/FileExplorerCore/LocationsBuilder.swift`. Pure function from raw inputs to ordered locations — no FileManager/NSWorkspace calls inside, so tests feed synthetic inputs.

```swift
public enum LocationKind: Sendable, Hashable {
    case icloud, cloud, thisMac, external, network
}

public struct Location: Identifiable, Hashable, Sendable {
    public let kind: LocationKind
    public let name: String
    public let url: URL
    public let isEjectable: Bool
    public var id: URL { url }
    public var systemImage: String { /* per kind, below */ }
}

public struct VolumeInfo: Sendable {   // raw resource values for one mounted volume
    public let url: URL
    public let name: String
    public let isRoot: Bool            // standardized path == "/"
    public let isInternal: Bool        // volumeIsInternal ?? false
    public let isEjectable: Bool       // volumeIsEjectable || volumeIsRemovable
    public let isLocal: Bool           // volumeIsLocal ?? true (false ⇒ network)
}

public enum LocationsBuilder {
    /// cloudFolders: (displayName, url) for each child of ~/Library/CloudStorage.
    /// icloudURL: non-nil when ~/Library/Mobile Documents/com~apple~CloudDocs exists.
    public static func build(volumes: [VolumeInfo],
                             cloudFolders: [(name: String, url: URL)],
                             icloudURL: URL?) -> [Location]
}
```

**Classification rules (per volume):**
- `isRoot` → `.thisMac` (keep the real volume name, e.g. "Macintosh HD")
- `!isLocal` → `.network`
- everything else → `.external` (internal non-root data volumes are rare with `skipHiddenVolumes`; classify `isInternal && !isRoot` as `.external` too — they're still navigable disks)
- `isEjectable` carries through only for non-root, ejectable/removable volumes (existing eject semantics).

**Ordering (Finder-style):** iCloud Drive, cloud providers (alphabetical by name, case-insensitive), This Mac, external drives (alphabetical), network shares (alphabetical).

**Dedupe:** by `url.standardizedFileURL.path` — the `/Volumes/Macintosh HD → /` symlink case collapses into the This Mac entry (standardization resolves it); duplicate provider folders can't occur but dedupe anyway for safety.

**Icons (`systemImage` computed per kind):** `.thisMac` → `internaldrive`, `.icloud` → `icloud`, `.cloud` → `cloud`, `.external` → `externaldrive`, `.network` → `server.rack`.

### App layer: `VolumesModel` → `LocationsModel`

Rename the existing `VolumesModel` (in `SidebarView.swift`) to `LocationsModel`, keeping its shape:
- Keep the three `NSWorkspace` notifications (mount/unmount/rename) → `refresh()`.
- Add a `DispatchSource.makeFileSystemObjectSource` watcher on `~/Library/CloudStorage` (`.write` events) so installing/removing a provider updates live. If the directory doesn't exist, skip the watcher (refresh still runs on mount events).
- `refresh()` gathers: `mountedVolumeURLs(includingResourceValuesForKeys: [name, isEjectable, isRemovable, isInternal, isLocal], options: [.skipHiddenVolumes])` → `[VolumeInfo]`; CloudStorage children (directories only, `FileManager.displayName(atPath:)` for names — gives the localized name Finder shows); iCloud path existence. Feeds `LocationsBuilder.build` and publishes `locations: [Location]`.
- Keep `isEjectable(_:)`/`eject(_:reportingTo:)` unchanged (drive them from the `Location.isEjectable` flags).

### Sidebar

`Section("Volumes")` becomes `Section("Locations")`, iterating `locationsModel.locations` with `Label(location.name, systemImage: location.systemImage)`, reusing the existing `row` navigation/highlight and the eject context menu for ejectable entries.

Navigation into a provider folder uses the existing `PaneState.navigate` — File Provider materializes directory listings on access, so dataless files still list (contents download on open, which is fine).

## Edge cases

- No `~/Library/CloudStorage` dir, or empty → no cloud entries, no crash.
- No iCloud (path missing) → entry absent.
- Recovery/hidden volumes stay excluded via `skipHiddenVolumes`.
- Volume with unreadable resource values → fall back to `lastPathComponent`, non-ejectable, `.external`.
- Session restore pointing into a since-removed provider folder is already handled by the existing watcher ancestor-fallback.

## Testing

`Sources/FileExplorerTests/LocationsBuilderTests.swift` (register in `main.swift`): classification per kind, root→thisMac, network via `isLocal=false`, ordering across all five kinds, alphabetical within groups, dedupe of root symlink, missing iCloud/empty cloud lists, ejectable flag propagation, fallback naming. Manual walkthrough: OneDrive entry appears/navigates, External SSD ejects, iCloud Drive lists, section updates on USB mount/unmount.

## Non-goals

- No sidebar show/hide preferences per location (YAGNI).
- No File Provider sync-status badges (download-state indicators) — future milestone if wanted.
- No "Network" browse entry (unmounted share discovery); only *mounted* network volumes show.
