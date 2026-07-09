import Foundation
import Observation

@MainActor
@Observable
public final class ScriptRunner {
    public var banner: String?
    public var pendingAlert: ScriptResultFormatter.AlertContent?
    public var onCompleted: (() -> Void)?

    private var running: [UUID: Process] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var dismissTask: Task<Void, Never>?

    public init() {}

    public func run(invocation: ScriptInvocationPlanner.Invocation,
                    timeout: Duration = .seconds(60)) {
        let id = UUID()
        let name = invocation.executable.lastPathComponent
        let process = Process()
        let stderr = Pipe()
        let stderrBuffer = LockedDataBuffer(limit: 4096)

        guard FileManager.default.fileExists(atPath: invocation.executable.path) else {
            pendingAlert = ScriptResultFormatter.launchFailureAlert(
                name: name,
                error: ScriptRunnerError.executableMissing(invocation.executable.path))
            return
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [invocation.executable.path] + invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            stderr.fileHandleForReading.readabilityHandler = nil
            let data = stderrBuffer.data()
            Task { @MainActor [weak self] in
                self?.finish(id: id, name: name,
                             exitCode: process.terminationStatus,
                             stderr: data)
            }
        }

        running[id] = process
        do {
            try process.run()
        } catch {
            running[id] = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            pendingAlert = ScriptResultFormatter.launchFailureAlert(name: name,
                                                                    error: error)
            return
        }

        timeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await MainActor.run { [weak self] in
                guard let self, self.running[id] != nil else { return }
                self.showBanner(ScriptResultFormatter.bannerText(
                    name: name, outcome: .stillRunning))
            }
        }
    }

    private func finish(id: UUID, name: String, exitCode: Int32, stderr: Data) {
        guard running.removeValue(forKey: id) != nil else { return }
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil

        if exitCode == 0 {
            showBanner(ScriptResultFormatter.bannerText(name: name,
                                                        outcome: .finished))
        } else {
            pendingAlert = ScriptResultFormatter.alert(
                name: name,
                exitCode: exitCode,
                stderr: ScriptResultFormatter.truncatedStderr(stderr))
        }
        onCompleted?()
    }

    private func showBanner(_ text: String) {
        banner = text
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            await MainActor.run { [weak self] in
                guard let self, self.banner == text else { return }
                self.banner = nil
            }
        }
    }
}

private enum ScriptRunnerError: Error, CustomStringConvertible {
    case executableMissing(String)

    var description: String {
        switch self {
        case .executableMissing(let path):
            return "Executable not found: \(path)"
        }
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var storage = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        if storage.count > limit {
            storage = storage.suffix(limit)
        }
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
    }
}
