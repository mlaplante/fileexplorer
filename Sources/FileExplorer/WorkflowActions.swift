import Foundation
import FileExplorerCore

@MainActor
enum WorkflowActions {
    static func selectedEntries(in pane: PaneState) -> [FileEntry] {
        SelectionResolver.entries(matching: pane.selection,
                                  in: pane.visibleEntries)
    }

    static func openInTerminal(pane: PaneState,
                               settings: SettingsModel,
                               scriptRunner: ScriptRunner,
                               selection: [FileEntry]? = nil) {
        guard let path = settings.settings.terminalAppPath else { return }
        let target = ScriptInvocationPlanner.terminalTarget(
            selection: selection ?? selectedEntries(in: pane),
            paneFolder: pane.currentURL)
        Task {
            let result = await AppLauncher.open(urls: [target], withAppAt: path)
            handleAppLaunch(result, kind: "Terminal", scriptRunner: scriptRunner)
        }
    }

    static func openInEditor(pane: PaneState,
                             settings: SettingsModel,
                             scriptRunner: ScriptRunner,
                             selection: [FileEntry]? = nil) {
        guard let path = settings.settings.editorAppPath else { return }
        let targets = ScriptInvocationPlanner.editorTargets(
            selection: selection ?? selectedEntries(in: pane),
            paneFolder: pane.currentURL)
        Task {
            let result = await AppLauncher.open(urls: targets, withAppAt: path)
            handleAppLaunch(result, kind: "Editor", scriptRunner: scriptRunner)
        }
    }

    static func runScript(_ script: URL,
                          pane: PaneState,
                          scriptRunner: ScriptRunner,
                          selection: [FileEntry]? = nil) {
        scriptRunner.run(
            invocation: ScriptInvocationPlanner.scriptInvocation(
                script: script,
                selection: selection ?? selectedEntries(in: pane),
                paneFolder: pane.currentURL),
            bannerPaneID: pane.id,
            onCompleted: { [weak pane] in
                guard let pane else { return }
                Task { await pane.reload() }
            })
    }

    static func openScriptsFolder(in pane: PaneState,
                                  scriptsModel: ScriptsModel,
                                  scriptRunner: ScriptRunner) {
        do {
            try scriptsModel.ensureFolderExistsAndRefresh()
            Task { await pane.navigate(to: ScriptLister.defaultFolder) }
        } catch {
            scriptRunner.pendingAlert = ScriptResultFormatter.AlertContent(
                title: "Scripts folder could not be opened",
                message: String(describing: error))
        }
    }

    static func handleAppLaunch(_ result: Result<Void, AppLaunchError>,
                                kind: String,
                                scriptRunner: ScriptRunner) {
        guard case .failure(let error) = result else { return }
        switch error {
        case .appMissing(let path):
            scriptRunner.pendingAlert = ScriptResultFormatter.AlertContent(
                title: "\(kind) app missing",
                message: "\(path) no longer exists. Open Settings > Integrations to choose another app.")
        case .openFailed(let message):
            scriptRunner.pendingAlert = ScriptResultFormatter.AlertContent(
                title: "\(kind) could not open",
                message: message)
        }
    }
}
