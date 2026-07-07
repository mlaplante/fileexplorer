import SwiftUI
import FileExplorerCore

struct PaletteOverlayView: View {
    @Bindable var palette: PaletteModel
    var onConfirm: (PaletteItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(palette.mode.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if palette.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            PaletteTextField(palette: palette) {
                if let item = palette.selection { onConfirm(item) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(palette.results.enumerated()),
                                id: \.element.id) { index, item in
                            row(item, selected: index == palette.selectedIndex)
                                .id(item.id)
                                .onTapGesture { onConfirm(item) }
                        }
                    }
                }
                .onChange(of: palette.selectedIndex) { _, newIndex in
                    if palette.results.indices.contains(newIndex) {
                        proxy.scrollTo(palette.results[newIndex].id)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 24)
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
    }
}
