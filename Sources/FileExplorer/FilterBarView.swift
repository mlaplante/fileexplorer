import SwiftUI
import FileExplorerCore

struct FilterBarView: View {
    @Bindable var pane: PaneState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TypePreset.allCases, id: \.self) { preset in
                Toggle(preset.rawValue, isOn: Binding(
                    get: { pane.filter.preset == preset },
                    set: { pane.filter.preset = $0 ? preset : nil }))
                    .toggleStyle(.button)
                    .controlSize(.small)
            }

            Divider().frame(height: 14)

            Menu {
                Button("Any Time") { pane.filter.datePreset = nil }
                Divider()
                ForEach(DatePreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) { pane.filter.datePreset = preset }
                }
            } label: {
                Label(pane.filter.datePreset?.rawValue ?? "Date",
                      systemImage: "calendar")
            }
            .controlSize(.small)
            .fixedSize()

            Menu {
                Button("Any Size") { pane.filter.sizePreset = nil }
                Divider()
                ForEach(SizePreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) { pane.filter.sizePreset = preset }
                }
            } label: {
                Label(pane.filter.sizePreset?.rawValue ?? "Size",
                      systemImage: "scalemass")
            }
            .controlSize(.small)
            .fixedSize()

            TextField("ext, ext…", text: $pane.filterExtensionsText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 120)

            Spacer()

            if pane.filter.isActive {
                Button("Clear") { pane.clearFilters() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}
