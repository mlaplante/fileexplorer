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
            // `deletingLastPathComponent()` is a purely lexical operation: at
            // the filesystem root ("/") it does NOT return "/" again, it
            // returns "/..". So the old "stop when the parent doesn't change
            // the path" check never fired at the root and this loop ran
            // forever, appending an ever-longer chain of "/../../.." URLs
            // (unbounded CPU + memory). Stop explicitly once we've appended
            // the root instead of asking for its "parent".
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        return urls.reversed()
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
