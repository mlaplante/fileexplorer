import SwiftUI
import AppKit
import FileExplorerCore

/// NSTextField bridge: self-focuses on appear and routes ↑/↓/Enter/Esc to the
/// palette (no focus-state wrapper on this toolchain).
struct PaletteTextField: NSViewRepresentable {
    @Bindable var palette: PaletteModel
    var onConfirm: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(palette: palette, onConfirm: onConfirm)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Type to search…"
        field.font = .systemFont(ofSize: 18)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onConfirm = onConfirm
        if field.stringValue != palette.query {
            field.stringValue = palette.query
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let palette: PaletteModel
        var onConfirm: () -> Void

        init(palette: PaletteModel, onConfirm: @escaping () -> Void) {
            self.palette = palette
            self.onConfirm = onConfirm
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            palette.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                palette.moveSelection(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                palette.moveSelection(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                onConfirm()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                palette.dismiss()
                return true
            default:
                return false
            }
        }
    }
}
