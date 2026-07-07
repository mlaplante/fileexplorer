import SwiftUI
import FileExplorerCore

struct TabBarView: View {
    @Bindable var session: SessionState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(session.tabs.enumerated()), id: \.element.id) { index, tab in
                chip(for: tab, at: index)
            }
            Button {
                session.newTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Tab (⌘T)")
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(.bar)
    }

    private func chip(for tab: TabState, at index: Int) -> some View {
        let isActive = index == session.activeTabIndex
        return HStack(spacing: 4) {
            Text(tab.title)
                .lineLimit(1)
                .font(.callout)
            if session.tabs.count > 1 {
                Button {
                    session.closeTab(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { session.selectTab(index) }
    }
}

/// Renders the tab bar plus only the ACTIVE tab's pane(s); inactive tabs keep
/// their state alive in SessionState but have no views.
struct TabContentView: View {
    @Bindable var session: SessionState

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(session: session)
            Divider()
            PaneAreaView(tab: session.activeTab)
        }
    }
}

/// Single- or dual-pane area for one tab, with active-pane highlight.
struct PaneAreaView: View {
    @Bindable var tab: TabState

    var body: some View {
        if tab.isDual {
            HSplitView {
                pane(at: 0)
                pane(at: 1)
            }
        } else {
            pane(at: 0)
        }
    }

    private func pane(at index: Int) -> some View {
        let paneState = tab.panes[index]
        return VStack(spacing: 0) {
            Rectangle()
                .fill(tab.isDual && index == tab.activePaneIndex
                      ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                .frame(height: 2)
            PaneView(pane: paneState)
        }
        .frame(minWidth: 300)
        .simultaneousGesture(TapGesture().onEnded {
            tab.activePaneIndex = index
        })
        .task(id: ObjectIdentifier(paneState)) {
            paneState.startIfNeeded()
        }
    }
}
