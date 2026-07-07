import SwiftUI
import FileExplorerCore

struct BreadcrumbView: View {
    @Bindable var pane: PaneState

    /// Ancestor URLs from root to the current folder, e.g.
    /// [/, /Users, /Users/mlaplante].
    private var crumbs: [URL] {
        var urls: [URL] = []
        var url = pane.currentURL.standardizedFileURL
        while true {
            urls.append(url)
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return urls.reversed()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(crumbs, id: \.self) { crumb in
                    Button {
                        Task { await pane.navigate(to: crumb) }
                    } label: {
                        Text(crumb.path == "/" ? "/" : crumb.lastPathComponent)
                            .fontWeight(crumb == crumbs.last ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    if crumb != crumbs.last {
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
