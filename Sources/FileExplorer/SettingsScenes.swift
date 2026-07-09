import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import FileExplorerCore

extension KeyChord {
    var keyboardShortcut: KeyboardShortcut? {
        guard let character = key.first, key.count == 1 else { return nil }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}

@MainActor
@Observable
final class ShortcutRecorderModel {
    var recordingCommand: ShortcutRegistry.Command?
    @ObservationIgnored private var monitor: Any?

    func beginRecording(_ command: ShortcutRegistry.Command,
                        settings: SettingsModel) {
        stopRecording()
        recordingCommand = command
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, settings] event in
            // NSEvent is non-Sendable, so it must not cross into
            // assumeIsolated: extract the Sendable facts first and return
            // a swallow decision out. Local key monitors fire on the main
            // thread, making the isolation assumption valid.
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers
            let flags = event.modifierFlags
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.recordingCommand != nil else { return false }
                if keyCode == 53 { // Escape cancels
                    self.stopRecording()
                    return true
                }
                guard let characters,
                      characters.count == 1,
                      characters.unicodeScalars.allSatisfy(Self.isRecordable(_:)),
                      flags.contains(.command)
                else { return true } // still recording: swallow non-chords
                let chord = KeyChord(
                    key: characters,
                    command: flags.contains(.command),
                    shift: flags.contains(.shift),
                    option: flags.contains(.option),
                    control: flags.contains(.control))
                settings.setShortcutOverride(chord, for: command)
                self.stopRecording()
                return true
            }
            return swallow ? nil : event
        }
    }

    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recordingCommand = nil
    }

    // isolated: a nonisolated deinit can't touch the non-Sendable monitor
    // (same pattern as LocationsModel's observer teardown).
    isolated deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private static func isRecordable(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(scalar)
            || CharacterSet.decimalDigits.contains(scalar)
            || CharacterSet.punctuationCharacters.contains(scalar)
    }
}

struct SettingsRootView: View {
    var settings: SettingsModel
    var updateModel: UpdateModel
    var recorder: ShortcutRecorderModel

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings, updateModel: updateModel)
                .tabItem { Label("General", systemImage: "gearshape") }
            IntegrationsSettingsView(settings: settings)
                .tabItem { Label("Integrations", systemImage: "app.connected.to.app.below.fill") }
            ShortcutSettingsView(settings: settings, recorder: recorder)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding()
    }
}

private struct GeneralSettingsView: View {
    var settings: SettingsModel
    var updateModel: UpdateModel

    var body: some View {
        Form {
            Picker("JPG quality", selection: Binding(
                get: { settings.settings.jpegQuality },
                set: { settings.setJPEGQuality($0) })) {
                Text("60%").tag(0.6)
                Text("80%").tag(0.8)
                Text("90%").tag(0.9)
                Text("100%").tag(1.0)
            }
            Toggle("Check for updates daily", isOn: Binding(
                get: { settings.settings.updateCheckEnabled },
                set: { settings.setUpdateCheckEnabled($0) }))
            HStack {
                Button("Check Now") { updateModel.check() }
                Text("Last checked: \(lastUpdateCheckText)")
            }
            if let version = updateModel.availableVersion {
                Text("FileExplorer \(version) is ready to install.")
            }
        }
        .frame(width: 420)
    }

    private var lastUpdateCheckText: String {
        guard let date = settings.settings.lastUpdateCheckAt else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct IntegrationsSettingsView: View {
    var settings: SettingsModel

    var body: some View {
        Form {
            appRow(title: "Terminal app",
                   path: settings.settings.terminalAppPath,
                   choose: { chooseApp { settings.setTerminalAppPath($0) } },
                   clear: { settings.setTerminalAppPath(nil) })
            appRow(title: "Editor app",
                   path: settings.settings.editorAppPath,
                   choose: { chooseApp { settings.setEditorAppPath($0) } },
                   clear: { settings.setEditorAppPath(nil) })
        }
        .frame(width: 520)
    }

    @ViewBuilder
    private func appRow(title: String, path: String?,
                        choose: @escaping () -> Void,
                        clear: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(displayName(for: path))
                .foregroundStyle(path == nil ? .secondary : .primary)
            Button("Choose…", action: choose)
            Button("Clear", action: clear)
                .disabled(path == nil)
        }
    }

    private func displayName(for path: String?) -> String {
        guard let path else { return "Not set" }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return name.isEmpty ? path : name
    }

    private func chooseApp(_ apply: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            apply(url.path)
        }
    }
}

private struct ShortcutSettingsView: View {
    var settings: SettingsModel
    var recorder: ShortcutRecorderModel

    var body: some View {
        Form {
            ForEach(ShortcutRegistry.Command.allCases, id: \.rawValue) { command in
                HStack {
                    Text(command.displayName)
                    Spacer()
                    Text(settings.chord(for: command).display)
                        .monospaced()
                    Button(recorder.recordingCommand == command ? "Press keys…" : "Record") {
                        recorder.beginRecording(command, settings: settings)
                    }
                    if settings.settings.shortcutOverrides[command.rawValue] != nil {
                        Button("Reset") {
                            settings.clearShortcutOverride(for: command)
                        }
                    }
                }
            }
            let conflicts = ShortcutRegistry.conflicts(
                overrides: settings.settings.shortcutOverrides)
            if !conflicts.isEmpty {
                Text(conflicts.map { group in
                    group.map(\.displayName).joined(separator: " ↔ ")
                }.joined(separator: "\n"))
                .font(.caption)
                .foregroundStyle(.red)
            }
            Button("Reset All") { settings.resetAllShortcuts() }
        }
        .frame(width: 520)
    }
}
