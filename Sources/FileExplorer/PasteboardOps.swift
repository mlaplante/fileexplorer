import AppKit

/// File-URL clipboard bridge. URLs are written as NSURL pasteboard objects
/// so copy/paste interoperates with Finder in both directions.
///
/// The app-level Edit commands that use this bridge replace SwiftUI's
/// default pasteboard group; because a replacement command intercepts
/// ⌘C/⌘V before text fields see them (rename sheet, filter bar), each
/// command checks whether a field editor owns focus and forwards to it via
/// the responder chain instead of acting on files.
@MainActor
enum PasteboardOps {
    static func copyToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    static func copyString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func readFileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingFileURLsOnly: true]
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }

    /// True when a text field editor owns focus in the key window.
    static var textEditingIsActive: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    static func forwardToFieldEditor(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
