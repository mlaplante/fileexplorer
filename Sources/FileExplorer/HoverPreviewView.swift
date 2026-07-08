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
            }
        }
        // Min bounds so small images scale UP instead of presenting a tiny
        // popover; max keeps huge renders from swallowing the screen.
        .frame(minWidth: 480, maxWidth: 960, minHeight: 480, maxHeight: 960)
        .padding(8)
    }
}
