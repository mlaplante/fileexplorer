import SwiftUI
import FileExplorerCore

/// Popover content. STATELESS — all render state lives on HoverPreviewModel
/// (view structs are re-initialized on parent re-render, so they must not
/// own async state on this no-@State toolchain).
struct HoverPreviewView: View {
    @Bindable var model: HoverPreviewModel

    var body: some View {
        Group {
            if let image = model.presentedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .frame(width: 128, height: 128)
            }
        }
        .frame(maxWidth: 512, maxHeight: 512)
        .padding(6)
    }
}
