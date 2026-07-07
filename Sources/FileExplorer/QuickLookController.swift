import AppKit
@preconcurrency import Quartz
import FileExplorerCore

/// Drives the shared QLPreviewPanel from the active pane: items are the
/// pane's visible FILES; the panel index follows the pane selection.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource,
                                 QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []

    func toggle(for pane: PaneState) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        urls = pane.visibleEntries.filter { !$0.isDirectory }.map(\.url)
        guard !urls.isEmpty else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        refresh(from: pane)
    }

    /// Re-syncs items + current index from the pane; call on selection change
    /// while the panel is visible.
    func refresh(from pane: PaneState) {
        urls = pane.visibleEntries.filter { !$0.isDirectory }.map(\.url)
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.reloadData()
        if let selected = pane.selection.first,
           let index = urls.firstIndex(of: selected) {
            panel.currentPreviewItemIndex = index
        }
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists()
            && QLPreviewPanel.shared().isVisible
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!,
                                  previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            urls.indices.contains(index) ? urls[index] as NSURL : nil
        }
    }
}
