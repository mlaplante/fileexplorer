import Foundation
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func scriptInvocationPlannerTests() async {
    func entry(_ name: String, dir: Bool = false) -> FileEntry {
        let url = URL(fileURLWithPath: "/tmp/pane/\(name)")
        return FileEntry(url: url, name: name, isDirectory: dir,
                         isHidden: false, isSymlink: false, size: 0,
                         created: nil, modified: .distantPast,
                         contentType: dir ? nil : UTType(filenameExtension: url.pathExtension))
    }

    let paneFolder = URL(fileURLWithPath: "/tmp/pane", isDirectory: true)
    let folder = entry("Folder", dir: true)
    let otherFolder = entry("Other", dir: true)
    let file = entry("notes.txt")
    let script = URL(fileURLWithPath: "/tmp/scripts/resize.sh")

    await test("ScriptInvocationPlanner resolves terminal target") {
        expectEqual(ScriptInvocationPlanner.terminalTarget(
            selection: [folder], paneFolder: paneFolder), folder.url,
                    "single selected folder opens in terminal")
        expectEqual(ScriptInvocationPlanner.terminalTarget(
            selection: [file], paneFolder: paneFolder), paneFolder,
                    "single selected file falls back to pane folder")
        expectEqual(ScriptInvocationPlanner.terminalTarget(
            selection: [folder, otherFolder], paneFolder: paneFolder), paneFolder,
                    "multi-selection falls back to pane folder")
        expectEqual(ScriptInvocationPlanner.terminalTarget(
            selection: [], paneFolder: paneFolder), paneFolder,
                    "empty selection opens pane folder")
    }

    await test("ScriptInvocationPlanner resolves editor targets") {
        expectEqual(ScriptInvocationPlanner.editorTargets(
            selection: [file, folder], paneFolder: paneFolder),
                    [file.url, folder.url],
                    "non-empty selection opens selected URLs in order")
        expectEqual(ScriptInvocationPlanner.editorTargets(
            selection: [], paneFolder: paneFolder), [paneFolder],
                    "empty selection opens pane folder")
    }

    await test("ScriptInvocationPlanner builds script invocation") {
        let selected = ScriptInvocationPlanner.scriptInvocation(
            script: script, selection: [file, folder], paneFolder: paneFolder)
        expectEqual(selected.executable, script, "script URL becomes executable")
        expectEqual(selected.arguments, [file.url.path, folder.url.path],
                    "selection paths are passed as argv in order")
        expectEqual(selected.workingDirectory, paneFolder,
                    "pane folder is always cwd")

        let empty = ScriptInvocationPlanner.scriptInvocation(
            script: script, selection: [], paneFolder: paneFolder)
        expectEqual(empty.arguments, [paneFolder.path],
                    "empty selection passes pane folder as sole argument")
        expectEqual(empty.workingDirectory, paneFolder,
                    "empty selection still uses pane folder as cwd")
    }
}
