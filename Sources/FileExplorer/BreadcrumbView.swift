import SwiftUI
import FileExplorerCore

struct BreadcrumbView: View {
    @Bindable var pane: PaneState

    /// Ancestor URLs from root to the current folder, e.g.
    /// [/, /Users, /Users/mlaplante].
    private var crumbs: [URL] {
        pane.currentURL.ancestorChain
    }

    var body: some View {
        // Computed once per body evaluation instead of once per ForEach row
        // (previously `crumbs` — which walks the URL chain — was
        // re-evaluated for every row via `crumbs.last`).
        let crumbs = crumbs
        let last = crumbs.last
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(crumbs, id: \.self) { crumb in
                    Button {
                        Task { await pane.navigate(to: crumb) }
                    } label: {
                        Text(crumb.path == "/" ? "/" : crumb.lastPathComponent)
                            .fontWeight(crumb == last ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    if crumb != last {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 24)
    }
}
