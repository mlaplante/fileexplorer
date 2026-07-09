import AppKit
import Foundation

@MainActor
enum AppLaunchError: Error, Equatable {
    case appMissing(String)
    case openFailed(String)
}

@MainActor
enum AppLauncher {
    static func open(urls: [URL], withAppAt path: String) async -> Result<Void, AppLaunchError> {
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.appMissing(path))
        }

        let appURL = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(urls,
                                    withApplicationAt: appURL,
                                    configuration: configuration) { _, error in
                if let error {
                    continuation.resume(returning: .failure(
                        .openFailed(String(describing: error))))
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }
    }
}
