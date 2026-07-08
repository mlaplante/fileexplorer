import SwiftUI
import AppKit

@MainActor
final class ShareBridge {
    static let shared = ShareBridge()

    private var picker: NSSharingServicePicker?

    func present(urls: [URL], from view: NSView) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        self.picker = picker
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }
}

struct ShareAnchor: NSViewRepresentable {
    let onResolve: @MainActor (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        onResolve(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onResolve(nsView)
    }
}
