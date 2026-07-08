import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Watches the session graph via Observation and writes `session.json`
/// after a short debounce; also saves synchronously at app termination.
///
/// `withObservationTracking`'s onChange fires once, so each change
/// re-registers. `saveNow()` snapshots at write time, so changes landing
/// between a fire and the re-registration are still captured by that write.
@MainActor
public final class SessionAutosaver {
    private let session: SessionState
    private let persister: SessionPersister
    private let debounceMilliseconds: Int
    private var pendingSave: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    public init(session: SessionState, persister: SessionPersister,
                debounceMilliseconds: Int = 500) {
        self.session = session
        self.persister = persister
        self.debounceMilliseconds = debounceMilliseconds
    }

    public func start() {
        observe()
        #if canImport(AppKit)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue; hop is safe.
            MainActor.assumeIsolated { self?.saveNow() }
        }
        #endif
    }

    public func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        persister.saveSession(session.snapshot())
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let delay = debounceMilliseconds
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func observe() {
        withObservationTracking {
            _ = session.snapshot()   // touches every persisted property
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleSave()
                self.observe()
            }
        }
    }

    isolated deinit {
        pendingSave?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }
}
