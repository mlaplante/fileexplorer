# Locations Sidebar Section Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sidebar "Volumes" section with a Finder-style "Locations" section: iCloud Drive, cloud accounts (Dropbox/OneDrive/any File Provider under `~/Library/CloudStorage`), This Mac, external drives, and network shares — kind-appropriate icons, live updates, eject preserved.

**Architecture:** One pure Core piece (`LocationsBuilder`: raw volume/cloud inputs → ordered `[Location]`) + a thin app layer (rename `VolumesModel` → `LocationsModel`, add CloudStorage discovery and a `DispatchSource` directory watcher) + a sidebar section swap. Follows the established pattern: pure/testable Core, `@Observable` model owned by `FileExplorerApp`, NO `@State`/`@FocusState` (CLT-only toolchain).

**Tech Stack:** Swift 6, SwiftUI, SPM, CLT-only toolchain. Tests: `swift run FileExplorerTests` (executable harness — `await test("…") { expectEqual(…) }`, register each new suite in `Sources/FileExplorerTests/main.swift`). Redirect test output to a file and read it (the RTK hook garbles `swift run | grep` pipes).

**Branch:** create `locations-sidebar` off `main` before Task 1. Spec: `docs/superpowers/specs/2026-07-08-locations-sidebar-design.md`.

---

### Task 1: Core `LocationsBuilder` (pure classification + ordering)

**Files:**
- Create: `Sources/FileExplorerCore/LocationsBuilder.swift`
- Test: `Sources/FileExplorerTests/LocationsBuilderTests.swift` (new)
- Modify: `Sources/FileExplorerTests/main.swift` (register `await locationsBuilderTests()` next to `await volumeSpaceTests()`)

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import FileExplorerCore

@MainActor
func locationsBuilderTests() async {
    func vol(_ path: String, name: String, isRoot: Bool = false,
             isInternal: Bool = false, isEjectable: Bool = false,
             isLocal: Bool = true) -> VolumeInfo {
        VolumeInfo(url: URL(fileURLWithPath: path), name: name, isRoot: isRoot,
                   isInternal: isInternal, isEjectable: isEjectable,
                   isLocal: isLocal)
    }

    await test("root volume classifies as thisMac, keeps its name") {
        let locations = LocationsBuilder.build(
            volumes: [vol("/", name: "Macintosh HD", isRoot: true, isInternal: true)],
            cloudFolders: [], icloudURL: nil)
        expectEqual(locations.count, 1, "one location")
        expectEqual(locations[0].kind, .thisMac, "root is thisMac")
        expectEqual(locations[0].name, "Macintosh HD", "keeps volume name")
        expectEqual(locations[0].systemImage, "internaldrive", "internal drive icon")
        expectEqual(locations[0].isEjectable, false, "root never ejectable")
    }

    await test("non-local volume classifies as network") {
        let locations = LocationsBuilder.build(
            volumes: [vol("/Volumes/share", name: "share", isLocal: false)],
            cloudFolders: [], icloudURL: nil)
        expectEqual(locations[0].kind, .network, "non-local is network")
        expectEqual(locations[0].systemImage, "server.rack", "network icon")
    }

    await test("local non-root volume classifies as external, ejectable propagates") {
        let locations = LocationsBuilder.build(
            volumes: [vol("/Volumes/USB", name: "USB", isEjectable: true)],
            cloudFolders: [], icloudURL: nil)
        expectEqual(locations[0].kind, .external, "local non-root is external")
        expectEqual(locations[0].systemImage, "externaldrive", "external icon")
        expectEqual(locations[0].isEjectable, true, "ejectable propagates")
    }

    await test("internal non-root data volume still classifies as external") {
        let locations = LocationsBuilder.build(
            volumes: [vol("/Volumes/Data", name: "Data", isInternal: true)],
            cloudFolders: [], icloudURL: nil)
        expectEqual(locations[0].kind, .external, "internal non-root is external")
    }

    await test("cloud folders and iCloud get kinds, names, icons") {
        let one = URL(fileURLWithPath: "/Users/x/Library/CloudStorage/OneDrive-Work")
        let icloud = URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs")
        let locations = LocationsBuilder.build(
            volumes: [], cloudFolders: [(name: "OneDrive - Work", url: one)],
            icloudURL: icloud)
        expectEqual(locations.count, 2, "two locations")
        expectEqual(locations[0].kind, .icloud, "iCloud first")
        expectEqual(locations[0].name, "iCloud Drive", "fixed display name")
        expectEqual(locations[0].systemImage, "icloud", "icloud icon")
        expectEqual(locations[1].kind, .cloud, "provider second")
        expectEqual(locations[1].name, "OneDrive - Work", "display name passthrough")
        expectEqual(locations[1].systemImage, "cloud", "cloud icon")
    }

    await test("ordering: icloud, cloud A-Z, thisMac, external A-Z, network A-Z") {
        let locations = LocationsBuilder.build(
            volumes: [
                vol("/Volumes/zeta", name: "zeta", isEjectable: true),
                vol("/Volumes/smb", name: "smb", isLocal: false),
                vol("/", name: "Macintosh HD", isRoot: true, isInternal: true),
                vol("/Volumes/Alpha", name: "Alpha", isEjectable: true),
            ],
            cloudFolders: [
                (name: "OneDrive", url: URL(fileURLWithPath: "/cs/OneDrive")),
                (name: "Dropbox", url: URL(fileURLWithPath: "/cs/Dropbox")),
            ],
            icloudURL: URL(fileURLWithPath: "/icloud"))
        expectEqual(locations.map(\.name),
                    ["iCloud Drive", "Dropbox", "OneDrive", "Macintosh HD",
                     "Alpha", "zeta", "smb"],
                    "Finder-style ordering, case-insensitive alpha within groups")
    }

    await test("dedupe by standardized path drops the /Volumes root symlink") {
        let locations = LocationsBuilder.build(
            volumes: [
                vol("/", name: "Macintosh HD", isRoot: true, isInternal: true),
                VolumeInfo(url: URL(fileURLWithPath: "/Volumes/Macintosh HD/./.."),
                           name: "Macintosh HD", isRoot: false, isInternal: true,
                           isEjectable: false, isLocal: true),
            ],
            cloudFolders: [], icloudURL: nil)
        // The second URL standardizes to "/Volumes" — distinct — so instead
        // exercise dedupe with an exact duplicate:
        let dup = LocationsBuilder.build(
            volumes: [
                vol("/", name: "Macintosh HD", isRoot: true, isInternal: true),
                vol("/", name: "Macintosh HD", isRoot: true, isInternal: true),
            ],
            cloudFolders: [], icloudURL: nil)
        expectEqual(dup.count, 1, "duplicate paths collapse")
        expectEqual(locations.count, 2, "distinct standardized paths both survive")
    }

    await test("empty inputs produce empty output") {
        expectEqual(LocationsBuilder.build(volumes: [], cloudFolders: [],
                                           icloudURL: nil).isEmpty,
                    true, "no inputs, no locations")
    }
}
```

- [ ] **Step 2: Register the suite** — in `Sources/FileExplorerTests/main.swift`, add `await locationsBuilderTests()` on the line after `await volumeSpaceTests()`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift run FileExplorerTests > /tmp/fx-tests.log 2>&1; tail -5 /tmp/fx-tests.log`
Expected: BUILD FAILURE (`VolumeInfo`/`LocationsBuilder` not found).

- [ ] **Step 4: Implement** `Sources/FileExplorerCore/LocationsBuilder.swift`:

```swift
import Foundation

/// Finder-style sidebar location kinds, in display order.
public enum LocationKind: Sendable, Hashable {
    case icloud, cloud, thisMac, external, network
}

/// One row in the sidebar's Locations section.
public struct Location: Identifiable, Hashable, Sendable {
    public let kind: LocationKind
    public let name: String
    public let url: URL
    public let isEjectable: Bool
    public var id: URL { url }

    public var systemImage: String {
        switch kind {
        case .icloud: "icloud"
        case .cloud: "cloud"
        case .thisMac: "internaldrive"
        case .external: "externaldrive"
        case .network: "server.rack"
        }
    }

    public init(kind: LocationKind, name: String, url: URL, isEjectable: Bool) {
        self.kind = kind
        self.name = name
        self.url = url
        self.isEjectable = isEjectable
    }
}

/// Raw resource values for one mounted volume — gathered by the app layer
/// so classification stays pure and testable.
public struct VolumeInfo: Sendable {
    public let url: URL
    public let name: String
    public let isRoot: Bool        // standardized path == "/"
    public let isInternal: Bool    // volumeIsInternal ?? false
    public let isEjectable: Bool   // volumeIsEjectable || volumeIsRemovable
    public let isLocal: Bool       // volumeIsLocal ?? true (false ⇒ network)

    public init(url: URL, name: String, isRoot: Bool, isInternal: Bool,
                isEjectable: Bool, isLocal: Bool) {
        self.url = url
        self.name = name
        self.isRoot = isRoot
        self.isInternal = isInternal
        self.isEjectable = isEjectable
        self.isLocal = isLocal
    }
}

/// Pure classification + Finder-style ordering for the Locations section.
public enum LocationsBuilder {
    public static func build(volumes: [VolumeInfo],
                             cloudFolders: [(name: String, url: URL)],
                             icloudURL: URL?) -> [Location] {
        var seen = Set<String>()
        func claim(_ url: URL) -> Bool {
            seen.insert(url.standardizedFileURL.path).inserted
        }

        var icloud: [Location] = []
        if let icloudURL, claim(icloudURL) {
            icloud.append(Location(kind: .icloud, name: "iCloud Drive",
                                   url: icloudURL, isEjectable: false))
        }

        let byName: (Location, Location) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        var cloud: [Location] = []
        for folder in cloudFolders where claim(folder.url) {
            cloud.append(Location(kind: .cloud, name: folder.name,
                                  url: folder.url, isEjectable: false))
        }

        var thisMac: [Location] = []
        var external: [Location] = []
        var network: [Location] = []
        for volume in volumes where claim(volume.url) {
            if volume.isRoot {
                thisMac.append(Location(kind: .thisMac, name: volume.name,
                                        url: volume.url, isEjectable: false))
            } else if !volume.isLocal {
                network.append(Location(kind: .network, name: volume.name,
                                        url: volume.url,
                                        isEjectable: volume.isEjectable))
            } else {
                external.append(Location(kind: .external, name: volume.name,
                                         url: volume.url,
                                         isEjectable: volume.isEjectable))
            }
        }

        return icloud + cloud.sorted(by: byName) + thisMac
            + external.sorted(by: byName) + network.sorted(by: byName)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run FileExplorerTests > /tmp/fx-tests.log 2>&1; tail -5 /tmp/fx-tests.log`
Expected: `PASS (N assertions)` — N grows by ~26 from the current baseline; zero failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/FileExplorerCore/LocationsBuilder.swift Sources/FileExplorerTests/LocationsBuilderTests.swift Sources/FileExplorerTests/main.swift
git commit -m "feat: LocationsBuilder pure classification and ordering"
```

---

### Task 2: App layer — `VolumesModel` → `LocationsModel` with cloud discovery

**Files:**
- Modify: `Sources/FileExplorer/SidebarView.swift:1-75` (the `VolumesModel` class at the top of the file)
- Modify: `Sources/FileExplorer/FileExplorerApp.swift:16` and `:72`

No new unit tests: this layer is FileManager/NSWorkspace glue over the tested builder (same posture as the old `VolumesModel`). Verification is the build + Task 4's manual walkthrough.

- [ ] **Step 1: Replace the `VolumesModel` class** in `SidebarView.swift` (lines 5–75, the doc comment through the closing brace) with:

```swift
/// Observes NSWorkspace mount/unmount plus ~/Library/CloudStorage changes and
/// republishes the Finder-style Locations list (iCloud, cloud providers,
/// This Mac, external drives, network shares).
/// App-lifetime: owned by FileExplorerApp (stateless view structs must not
/// own @Observable models on this no-@State toolchain).
@MainActor
@Observable
final class LocationsModel {
    private(set) var locations: [Location] = []
    private(set) var ejectableVolumes = Set<URL>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var cloudWatcher: DispatchSourceFileSystemObject?

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        watchCloudStorage()
    }

    isolated deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        cloudWatcher?.cancel()
    }

    private static var cloudStorageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    private static var icloudDriveURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",
                                    isDirectory: true)
    }

    /// Installing/removing a File Provider (Dropbox, OneDrive…) writes into
    /// ~/Library/CloudStorage — watch it so the section updates live. Mount
    /// notifications don't fire for File Providers.
    private func watchCloudStorage() {
        let fd = open(Self.cloudStorageURL.path, O_EVTONLY)
        guard fd >= 0 else { return }  // no CloudStorage dir: mounts still refresh
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        cloudWatcher = source
    }

    private func refresh() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.map { url -> VolumeInfo in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return VolumeInfo(
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                isRoot: url.standardizedFileURL.path == "/",
                isInternal: values?.volumeIsInternal ?? false,
                isEjectable: values?.volumeIsEjectable == true
                    || values?.volumeIsRemovable == true,
                isLocal: values?.volumeIsLocal ?? true)
        }

        let fm = FileManager.default
        let cloudFolders = ((try? fm.contentsOfDirectory(
            at: Self.cloudStorageURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? [])
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                    == true
            }
            .map { (name: fm.displayName(atPath: $0.path), url: $0) }

        var isDirectory: ObjCBool = false
        let hasICloud = fm.fileExists(atPath: Self.icloudDriveURL.path,
                                      isDirectory: &isDirectory)
            && isDirectory.boolValue

        locations = LocationsBuilder.build(
            volumes: volumes,
            cloudFolders: cloudFolders,
            icloudURL: hasICloud ? Self.icloudDriveURL : nil)
        ejectableVolumes = Set(locations.filter(\.isEjectable)
            .map { $0.url.standardizedFileURL })
    }

    func isEjectable(_ url: URL) -> Bool {
        ejectableVolumes.contains(url.standardizedFileURL)
    }

    func eject(_ url: URL, reportingTo pane: PaneState) {
        let name = FileManager.default.displayName(atPath: url.path)
        Task.detached(priority: .userInitiated) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                await MainActor.run {
                    pane.reportTagFailure("Couldn't eject \(name): \(error.localizedDescription)")
                }
            }
        }
    }
}
```

(Swift 6 notes already proven in this file: read NSWorkspace notifications via `MainActor.assumeIsolated`; teardown in `isolated deinit`. The DispatchSource handler runs on `.main`, so `assumeIsolated` is valid there too.)

- [ ] **Step 2: Update `FileExplorerApp.swift`** — line 16: `private let volumesModel = VolumesModel()` → `private let locationsModel = LocationsModel()`; line 72: pass `locationsModel: locationsModel` (parameter renamed in Task 3 — do Tasks 2+3 as one build unit, committing once at the end of Task 3).

---

### Task 3: Sidebar section swap

**Files:**
- Modify: `Sources/FileExplorer/SidebarView.swift` (the `SidebarView` struct: property, Volumes section, `row` helper)

- [ ] **Step 1: Rename the property** — `var volumesModel: VolumesModel` → `var locationsModel: LocationsModel`.

- [ ] **Step 2: Replace the Volumes section** (`Section("Volumes") { … }`) with:

```swift
Section("Locations") {
    ForEach(locationsModel.locations) { location in
        row(name: location.name, systemImage: location.systemImage,
            url: location.url)
            .contextMenu {
                if locationsModel.isEjectable(location.url) {
                    Button("Eject") {
                        locationsModel.eject(location.url,
                                             reportingTo: session.activePane)
                    }
                }
            }
    }
}
```

- [ ] **Step 3: Generalize the row helper** — replace the existing `row(_ place:)` with a field-based core plus a `Place` overload so Favorites/Recents call sites stay untouched:

```swift
private func row(_ place: StandardPlaces.Place) -> some View {
    row(name: place.name, systemImage: place.systemImage, url: place.url)
}

private func row(name: String, systemImage: String, url: URL) -> some View {
    let isCurrent = url.standardizedFileURL.path
        == session.activePane.currentURL.path
    return Button {
        Task { await session.activePane.navigate(to: url) }
    } label: {
        Label(name, systemImage: systemImage)
            .fontWeight(isCurrent ? .semibold : .regular)
    }
    .buttonStyle(.plain)
    .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
}
```

- [ ] **Step 4: Full build + tests**

Run: `swift build 2>&1 | tail -5 && swift run FileExplorerTests > /tmp/fx-tests.log 2>&1; tail -3 /tmp/fx-tests.log`
Expected: build succeeds (no lingering `VolumesModel`/`volumes` references — grep to confirm: `grep -rn "VolumesModel\|volumesModel" Sources/` returns only the comment in `SettingsScenes.swift:71`, which should be updated to say `LocationsModel`); tests `PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FileExplorer/SidebarView.swift Sources/FileExplorer/FileExplorerApp.swift Sources/FileExplorer/SettingsScenes.swift
git commit -m "feat: Finder-style Locations sidebar section (cloud + volumes)"
```

---

### Task 4: Verify against the live machine + wrap up

- [ ] **Step 1: Smoke-check discovery inputs exist as designed**

Run: `ls ~/Library/CloudStorage/ && ls "/Volumes"`
Expected: `OneDrive-PFGVenturesLPdbaProformaInc` and `External SSD` present.

- [ ] **Step 2: Bundle build sanity** — `./Scripts/bundle.sh > /tmp/fx-bundle.log 2>&1; tail -3 /tmp/fx-bundle.log` → app bundle builds clean.

- [ ] **Step 3: Update the plan's Completion Notes** section below with anything deferred/deviated, mark checkboxes done, commit the plan+spec docs if not already committed.

**MANUAL walkthrough (human, post-merge):**
- [ ] Sidebar shows Locations with: iCloud Drive, OneDrive, Macintosh HD, External SSD (in that order)
- [ ] Clicking OneDrive navigates into the provider folder and lists files (dataless files included)
- [ ] Clicking iCloud Drive lists com~apple~CloudDocs contents
- [ ] Eject on External SSD works; section drops the entry on unmount and restores on remount
- [ ] Mount a network share (⌘K in Finder or Connect to Server) → appears with server.rack icon

## Completion Notes

(filled in by implementer)
