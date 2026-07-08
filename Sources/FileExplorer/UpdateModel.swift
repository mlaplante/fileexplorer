import Foundation
import AppKit
import Observation
import FileExplorerCore

/// Launch-time release check: throttled, toggleable, silent on failure.
@MainActor
@Observable
final class UpdateModel {
    private(set) var availableVersion: String?
    private(set) var releaseURL: URL?

    private static let latestReleaseAPI = URL(string:
        "https://api.github.com/repos/mlaplante/fileexplorer/releases/latest")!

    func checkIfDue(settings: SettingsModel) {
        guard settings.settings.updateCheckEnabled,
              UpdateChecker.isDue(lastCheck: settings.settings.lastUpdateCheckAt)
        else { return }
        settings.markUpdateCheck()
        check()
    }

    /// Unthrottled (Settings "Check Now" also uses this).
    func check() {
        let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "0"
        Task {
            guard let (data, response) = try? await URLSession.shared.data(
                    from: Self.latestReleaseAPI),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any],
                  let tag = payload["tag_name"] as? String
            else { return }   // silent: network/parse failures are invisible
            if UpdateChecker.isNewer(remote: tag, local: local) {
                availableVersion = tag
                releaseURL = (payload["html_url"] as? String).flatMap(URL.init)
                    ?? URL(string: "https://github.com/mlaplante/fileexplorer/releases")
            }
        }
    }

    func dismiss() { availableVersion = nil }

    func openReleasePage() {
        if let releaseURL { NSWorkspace.shared.open(releaseURL) }
        dismiss()
    }
}
