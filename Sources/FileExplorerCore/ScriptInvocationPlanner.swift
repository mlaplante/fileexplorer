import Foundation

public enum ScriptInvocationPlanner {
    public struct Invocation: Equatable, Sendable {
        public let executable: URL
        public let arguments: [String]
        public let workingDirectory: URL

        public init(executable: URL, arguments: [String], workingDirectory: URL) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
        }
    }

    public static func terminalTarget(selection: [FileEntry],
                                      paneFolder: URL) -> URL {
        guard selection.count == 1, let selected = selection.first,
              selected.isDirectory else {
            return paneFolder
        }
        return selected.url
    }

    public static func editorTargets(selection: [FileEntry],
                                     paneFolder: URL) -> [URL] {
        selection.isEmpty ? [paneFolder] : selection.map(\.url)
    }

    public static func scriptInvocation(script: URL,
                                        selection: [FileEntry],
                                        paneFolder: URL) -> Invocation {
        Invocation(executable: script,
                   arguments: selection.isEmpty
                        ? [paneFolder.path]
                        : selection.map { $0.url.path },
                   workingDirectory: paneFolder)
    }
}
