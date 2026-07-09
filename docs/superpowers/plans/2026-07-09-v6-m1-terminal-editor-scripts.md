# V6 M1 — Open in Terminal / Editor + User Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jump from a pane to a configured terminal or editor with one command, and run user scripts from `~/Library/Application Support/FileExplorer/Scripts` against the selection, with banner/alert feedback.

**Architecture:** Pure Core logic first (`ScriptLister`, `ScriptInvocationPlanner`, `ScriptResultFormatter`), thin app-side shims second (`AppLauncher` around `NSWorkspace`, `ScriptRunner` around `Process`). Settings gain two optional app-bundle paths; two new `ShortcutRegistry` commands ride the existing customizable-shortcut plumbing.

**Tech Stack:** Swift 6, SwiftUI, SPM, CLT-only toolchain. Spec: `docs/superpowers/specs/2026-07-09-terminal-editor-scripts-design.md`. Branch: `v6-terminal-editor-scripts` (already created off main).

---

## HARD TOOLCHAIN CONSTRAINTS (read first)

- **No Xcode — CLT only.** Build with `swift build`; NEVER `xcodebuild` or `swift test`.
- **`@State`/`@FocusState` DO NOT COMPILE.** Transient UI state lives on `@Observable` models (see `PaneState.showsNewTagPopover` precedent).
- Tests are a plain executable: `swift run FileExplorerTests` — exit 0 + `PASS (N assertions)`. Register new suites in `Sources/FileExplorerTests/main.swift`.
- Redirect test output to a file and read the file (`swift run FileExplorerTests > /tmp/fx-m1-tests.log 2>&1; tail -5 /tmp/fx-m1-tests.log`) — piping through grep can mask a SIGABRT.
- Swift 6 strict concurrency: app models are `@MainActor @Observable`. `Process` termination handlers arrive on a background queue — hop to the main actor before touching model state.
- Commit after each task with a conventional message. Do not push.

### Task 1: Settings fields (terminal/editor app paths)

**Files:**
- Modify: `Sources/FileExplorerCore/SessionPersister.swift` (`AppSettings`), `Sources/FileExplorerCore/SettingsModel.swift`
- Test: extend `Sources/FileExplorerTests/SettingsModelTests.swift`

- [ ] **Step 1: Failing tests** — (a) `AppSettings` round-trips `terminalAppPath: String?` and `editorAppPath: String?` through encode/decode; (b) a settings JSON literal **without** the new keys decodes with both nil (paste a current-format JSON literal, per the existing legacy-decode tests in `SettingsModelTests`); (c) `SettingsModel.setTerminalAppPath("/Applications/iTerm.app")` and `setEditorAppPath(...)` update `settings` and persist (drive with the injected-persister pattern the existing settings tests use); (d) setting nil clears.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement: add both fields to `AppSettings` (memberwise init defaults nil, `CodingKeys` entries, `decodeIfPresent` in `init(from:)`); add `SettingsModel.setTerminalAppPath(_ path: String?)` / `setEditorAppPath(_ path: String?)` following the `setUpdateCheckEnabled` shape.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat: terminal/editor app settings fields`

### Task 2: ScriptInvocationPlanner (targets, argv, cwd — pure)

**Files:**
- Create: `Sources/FileExplorerCore/ScriptInvocationPlanner.swift`
- Test: `Sources/FileExplorerTests/ScriptInvocationPlannerTests.swift`, register `await scriptInvocationPlannerTests()`

- [ ] **Step 1: Failing tests** — pure functions over URLs/flags (no filesystem):
  - `terminalTarget(selection: [FileEntry], paneFolder: URL) -> URL`: (a) exactly one selected entry with `isDirectory == true` → that folder; (b) single selected file → pane folder; (c) multi-selection (even all folders) → pane folder; (d) empty selection → pane folder. Build `FileEntry` fixtures the way `FilterEngineTests` does.
  - `editorTargets(selection: [FileEntry], paneFolder: URL) -> [URL]`: (a) non-empty selection → all selected URLs in order; (b) empty → `[paneFolder]`.
  - `scriptInvocation(script: URL, selection: [FileEntry], paneFolder: URL) -> Invocation` where `struct Invocation: Equatable { let executable: URL; let arguments: [String]; let workingDirectory: URL }`: (a) arguments are the selected paths in order; (b) empty selection → arguments = `[paneFolder.path]` (scripts always get ≥1 path); (c) workingDirectory = paneFolder always.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (pure `enum ScriptInvocationPlanner`). **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat: ScriptInvocationPlanner target and argv resolution`

### Task 3: ScriptLister (executable discovery — real temp dirs)

**Files:**
- Create: `Sources/FileExplorerCore/ScriptLister.swift`
- Test: `Sources/FileExplorerTests/ScriptListerTests.swift`, register `await scriptListerTests()`

- [ ] **Step 1: Failing tests** — `ScriptLister.scripts(in: URL) -> [URL]` against real temp directories (mkdir under `FileManager.default.temporaryDirectory`, chmod via `FileManager.setAttributes([.posixPermissions: 0o755])`):
  - (a) executable regular files returned, sorted by localized-standard name;
  - (b) non-executable file (0o644) skipped;
  - (c) subdirectory skipped (even though directories test "executable");
  - (d) executable **symlink to an executable file** included; broken symlink skipped;
  - (e) dotfiles skipped;
  - (f) nonexistent/unreadable folder → `[]` (no throw).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (`contentsOfDirectory(at:includingPropertiesForKeys:[.isRegularFileKey, .isExecutableKey, .isSymbolicLinkKey])`; for symlinks resolve and re-check regular+executable). **Step 4:** Run → PASS.
- [ ] **Step 5:** Also add `ScriptLister.defaultFolder` = `~/Library/Application Support/FileExplorer/Scripts` derived the same way `SessionPersister` derives its App Support directory (read `SessionPersister.swift` first and reuse its helper if one exists; otherwise `FileManager.urls(for: .applicationSupportDirectory, ...)`), plus `ScriptLister.ensureFolderExists(_:)` creating intermediate directories. Test: creates the folder in a temp App-Support-shaped root; idempotent on second call.
- [ ] **Step 6:** Run → PASS. Commit: `feat: ScriptLister executable discovery`

### Task 4: ScriptResultFormatter (banner/alert text — pure)

**Files:**
- Create: `Sources/FileExplorerCore/ScriptResultFormatter.swift`
- Test: `Sources/FileExplorerTests/ScriptResultFormatterTests.swift`, register `await scriptResultFormatterTests()`

- [ ] **Step 1: Failing tests** —
  - `bannerText(name: "resize.sh", outcome: .finished)` → `"resize.sh finished"`; `outcome: .stillRunning` → `"resize.sh still running…"`.
  - `alert(name:exitCode:stderr:)` → `struct AlertContent: Equatable { let title: String; let message: String }` with title `"resize.sh failed (exit 2)"` and message = stderr trimmed of trailing whitespace; empty stderr → message `"(no error output)"`.
  - `truncatedStderr(_ data: Data) -> String`: (a) ≤ 4096 bytes → full UTF-8 string; (b) > 4096 bytes → **last** 4096 bytes decoded lossily, prefixed with `"…"` (tail is where the error is); (c) invalid UTF-8 → lossy decode, no crash.
  - `launchFailureAlert(name:error:)` → title `"resize.sh could not start"`, message = error text.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement pure `enum ScriptResultFormatter` + `enum ScriptOutcome { case finished, stillRunning }`. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat: ScriptResultFormatter banner and alert text`

### Task 5: ScriptRunner (Process launch + timeout, app target)

**Files:**
- Create: `Sources/FileExplorer/ScriptRunner.swift`
- Test: `Sources/FileExplorerTests/ScriptRunnerTests.swift`, register `await scriptRunnerTests()` — the runner must live where the test target can import it. **If the tests target only imports FileExplorerCore (check `Package.swift` target deps first), put ScriptRunner in `Sources/FileExplorerCore/ScriptRunner.swift` instead** — it has no AppKit dependency (Foundation `Process` only), so Core is a legitimate home.

- [ ] **Step 1: Failing tests** — `@MainActor @Observable final class ScriptRunner` with:
  - `run(invocation: ScriptInvocationPlanner.Invocation, timeout: Duration = .seconds(60))`;
  - published state: `banner: String?` (transient text) and `pendingAlert: ScriptResultFormatter.AlertContent?`;
  - completion callback `onCompleted: (() -> Void)?` (the app wires pane reload here).
  Tests use real shell scripts written to temp dirs (0o755, `#!/bin/sh` shebang), injected short timeout (e.g. `.milliseconds(80)`), and `Task.sleep` polling:
  - (a) exit-0 script → `banner` becomes `"<name> finished"`, `onCompleted` fired, no alert;
  - (b) exit-2 script writing to stderr → `pendingAlert` title contains `exit 2`, message contains the stderr text, `onCompleted` fired;
  - (c) script sleeping past the injected timeout → banner flips to `"<name> still running…"` while the process lives, and when it finally exits the terminal state (banner/alert) still lands — the process is never killed;
  - (d) invocation pointing at a nonexistent executable → `pendingAlert` = launch-failure content, no crash;
  - (e) script receives argv and cwd: script `pwd > out.txt; echo "$@" >> out.txt` — assert file contents match invocation.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement: `Process` with `executableURL`, `arguments`, `currentDirectoryURL`; stderr → `Pipe` drained on a background thread into `Data` (cap reads; keep last 4 KB via `ScriptResultFormatter.truncatedStderr`); stdout → `FileHandle.nullDevice`. `terminationHandler` hops to `@MainActor` (`Task { @MainActor in … }`). Timeout via a main-actor `Task.sleep` racing a `finished` flag. Banner auto-dismiss after ~2.5 s via another sleeping Task (cancel-safe). Keep strong references to running processes in a `[UUID: Process]` dictionary until termination.
- [ ] **Step 4:** Run → PASS (mind flakiness: poll with deadline loops, not fixed sleeps — see `SpringLoadModel` tests for the pattern).
- [ ] **Step 5:** Commit: `feat: ScriptRunner process execution with timeout and feedback state`

### Task 6: AppLauncher + shortcut registry commands

**Files:**
- Create: `Sources/FileExplorer/AppLauncher.swift`
- Modify: `Sources/FileExplorerCore/ShortcutRegistry.swift`
- Test: extend `Sources/FileExplorerTests/ShortcutTests.swift`

- [ ] **Step 1: Failing tests** — `ShortcutRegistry.Command` gains `.openInTerminal` (display "Open in Terminal", default chord ⌃⌘T: `KeyChord(key: "t", command: true, shift: false, option: false, control: true)`) and `.openInEditor` ("Open in Editor", ⌃⌘E). Assert both exist with those defaults and `conflicts(overrides: [:])` stays empty.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement registry additions. **Step 4:** Run → PASS.
- [ ] **Step 5:** `AppLauncher` (app target, `@MainActor` enum): `open(urls: [URL], withAppAt path: String) async -> Result<Void, AppLaunchError>` using `NSWorkspace.shared.open(_:withApplicationAt:configuration:)` (`NSWorkspace.OpenConfiguration()`, activates by default); `enum AppLaunchError: Error { case appMissing(String), openFailed(String) }` — `appMissing` when `FileManager.default.fileExists` is false at the bundle path. No unit tests (launches real apps) — logic is 15 lines; manual walkthrough covers it.
- [ ] **Step 6:** Build clean + tests PASS. Commit: `feat: openInTerminal/openInEditor shortcut commands and AppLauncher shim`

### Task 7: Menu, palette, banner, and Settings UI wiring

**Files:**
- Modify: `Sources/FileExplorer/FileExplorerApp.swift` (File menu items + command handlers), `Sources/FileExplorer/FileActionsMenu.swift` (context-menu entries), `Sources/FileExplorer/PaletteCoordinator.swift` (palette commands — read how existing registry commands surface there first; if the palette enumerates `ShortcutRegistry.Command.allCases` the two new commands appear for free, and only the Scripts entries need explicit wiring), `Sources/FileExplorer/SettingsScenes.swift` (Integrations section), `Sources/FileExplorer/PaneView.swift` (banner display)
- Test: none new (view layer) — existing suites stay green

- [ ] **Step 1: File menu** — after the existing open/share block: "Open in Terminal" and "Open in Editor" (keyboard shortcuts via the same `settings.chord(for:)` mechanism the other registry commands use — copy the `getInfo` menu-item wiring exactly), then a `Menu("Scripts")` that on open (`onAppear` inside the menu content or recomputed per render — menus rebuild on open in SwiftUI) lists `ScriptLister.scripts(in: ScriptLister.defaultFolder)` by display name, a divider, and "Open Scripts Folder" (ensures folder exists via `ScriptLister.ensureFolderExists`, then `NSWorkspace.shared.activateFileViewerSelecting` or opens it in the active pane — match how "Go to Folder" navigates and prefer navigating the active pane). Unreadable/empty scripts folder → single disabled item "No scripts installed".
- [ ] **Step 2: Handlers** — Open in Terminal: resolve target via `ScriptInvocationPlanner.terminalTarget(selection:paneFolder:)` with the active pane's selected entries + current folder; nil/unset `terminalAppPath` → disable the menu item; stored path missing on disk → `AppLauncher` returns `.appMissing` → alert with "Open Settings…" button (`SettingsLink` or the existing route to the Settings scene — check how the app opens Settings programmatically; if there is no precedent, the alert just names Settings → Integrations). Open in Editor: same via `editorTargets`. Script selection: build invocation via `scriptInvocation(script:selection:paneFolder:)`, hand to a single app-lifetime `ScriptRunner` owned by `FileExplorerApp` (alongside the other app-lifetime models), whose `onCompleted` reloads the active pane (`Task { await pane.reload() }`).
- [ ] **Step 3: Context menu** — `FileActionsMenu` gains the same three entries (two Opens + Scripts submenu) in a "workflow" group near "Share…"; identical handlers (they act on the menu's target selection, matching how existing items resolve their URLs).
- [ ] **Step 4: Banner** — `PaneView` (or the pane-column container in `TabBarView` — put it where CompareBannerView mounts, but per-pane): when `scriptRunner.banner != nil`, show a one-line capsule overlay at the pane's bottom edge (`.font(.caption)`, `.background(.quaternary.opacity(0.5))` — CompareBannerView's palette), auto-dismissed by ScriptRunner. When `scriptRunner.pendingAlert != nil`, present via `.alert(item:)`-equivalent for `@Observable` (manual `Binding(get:set:)` over the model property, the pattern the existing sheets use — see `RenameSheet` presentation).
- [ ] **Step 5: Settings UI** — `SettingsScenes.swift`: new "Integrations" group (own tab if settings use tabs; otherwise a `GroupBox` in General): two rows "Terminal app" / "Editor app", each showing the current bundle name (last path component sans `.app`) or "Not set", a "Choose…" button running `NSOpenPanel` (`allowedContentTypes = [.applicationBundle]`, `directoryURL = /Applications`) and a "Clear" button (sets nil). Persist through the Task-1 setters.
- [ ] **Step 6:** `swift build` clean; full test suite PASS; run the app briefly (`swift run FileExplorer`) to confirm menus render.
- [ ] **Step 7:** Commit: `feat: terminal/editor/scripts commands wired to menus, palette, settings, and banner`

### Task 8: README + walkthrough notes

- [ ] README: add ⌃⌘T / ⌃⌘E rows to the shortcut table, a "Terminal, editor, and scripts" bullet under Finder power features, and a short "User scripts" subsection (folder path, argv/cwd contract, feedback behavior).
- [ ] Full `swift run FileExplorerTests` → PASS; `./Scripts/bundle.sh` builds.
- [ ] Commit: `docs: terminal/editor/scripts usage and shortcuts`. No tag/version bump — v6 ships after all four M-milestones; manual walkthrough items (real iTerm2/VS Code launches, banner feel, long script, missing-app alert) join the pending list.
