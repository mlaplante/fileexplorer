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
    var renameModel: RenameSheetModel
    var batchRenameModel: BatchRenameModel
    var syncPreview: SyncPreviewModel
    var settings: SettingsModel
    var trashRegistry: TrashRegistryModel?

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(session: session)
            Divider()
            PaneAreaView(session: session, tab: session.activeTab,
                         renameModel: renameModel,
                         batchRenameModel: batchRenameModel,
                         syncPreview: syncPreview, settings: settings,
                         trashRegistry: trashRegistry)
        }
        .onChange(of: session.activeTabIndex) { _, _ in
            if QuickLookController.shared.isVisible {
                QuickLookController.shared.refresh(from: session.activePane)
            }
        }
    }
}

/// Single- or dual-pane area for one tab, with active-pane highlight.
struct PaneAreaView: View {
    @Bindable var session: SessionState
    @Bindable var tab: TabState
    var renameModel: RenameSheetModel
    var batchRenameModel: BatchRenameModel
    var syncPreview: SyncPreviewModel
    var settings: SettingsModel
    var trashRegistry: TrashRegistryModel?

    var body: some View {
        HSplitView {
            browserArea
            if tab.showsPreviewPane {
                PreviewPaneView(pane: tab.activePane, model: tab.previewPane)
                    .frame(width: 280)
            }
        }
        .onChange(of: tab.activePaneIndex) { _, _ in
            if QuickLookController.shared.isVisible {
                QuickLookController.shared.refresh(from: tab.activePane)
            }
            tab.previewPane.update(selection: tab.activePane.selection,
                                   entries: tab.activePane.entries)
        }
    }

    @ViewBuilder
    private var browserArea: some View {
        if tab.isDual {
            VStack(spacing: 0) {
                if tabCompareActive {
                    CompareBannerView(tab: tab, syncPreview: syncPreview)
                }
                HSplitView {
                    pane(at: 0)
                    pane(at: 1)
                }
            }
        } else {
            pane(at: 0)
        }
    }

    // Badges are only valid while both panes remain at the compared roots.
    private var tabCompareActive: Bool {
        tab.isDual
            && tab.compareResult != nil
            && tab.compareLeftRoot == tab.panes[0].currentURL.standardizedFileURL
            && tab.compareRightRoot == tab.panes[1].currentURL.standardizedFileURL
    }

    private func pane(at index: Int) -> some View {
        let paneState = tab.panes[index]
        let compareActive = tabCompareActive
        return VStack(spacing: 0) {
            Rectangle()
                .fill(tab.isDual && index == tab.activePaneIndex
                      ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                .frame(height: 2)
            PaneView(pane: paneState,
                     session: session,
                     otherPane: tab.isDual ? tab.panes[1 - index] : nil,
                     renameModel: renameModel,
                     batchRenameModel: batchRenameModel,
                     settings: settings,
                     trashRegistry: trashRegistry,
                     compareSide: compareActive ? (index == 0 ? .left : .right) : nil,
                     compareResult: compareActive ? tab.compareResult : nil)
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
