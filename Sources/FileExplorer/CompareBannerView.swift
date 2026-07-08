import SwiftUI
import FileExplorerCore

/// Shown above the panes while compare mode is active: counts + sync actions.
struct CompareBannerView: View {
    var tab: TabState
    var syncPreview: SyncPreviewModel

    var body: some View {
        if let result = tab.compareResult {
            HStack(spacing: 12) {
                Label("\(result.onlyLeft.count) only left", systemImage: "arrow.left")
                Label("\(result.onlyRight.count) only right", systemImage: "arrow.right")
                Label("\(result.differs.count) differ",
                      systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Button("Sync → Right") {
                    syncPreview.present(direction: .leftToRight, tab: tab)
                }
                .disabled(result.onlyLeft.isEmpty && result.differs.isEmpty)
                Button("Sync ← Left") {
                    syncPreview.present(direction: .rightToLeft, tab: tab)
                }
                .disabled(result.onlyRight.isEmpty && result.differs.isEmpty)
                Button("Done") { tab.endCompare() }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(.quaternary.opacity(0.5))
        }
    }
}
