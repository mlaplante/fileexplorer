import SwiftUI
import FileExplorerCore

@MainActor
@Observable
final class ConnectServerModel {
    var isPresented = false
    var address = ""
    var errorMessage: String?

    func present() {
        address = ""
        errorMessage = nil
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        errorMessage = nil
    }
}

struct ConnectServerSheet: View {
    @Bindable var model: ConnectServerModel
    var connect: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Server")
                .font(.headline)
            TextField("smb://server/share", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                Button("Connect") {
                    guard let url = ServerConnector.normalizedURL(
                        from: model.address) else {
                        model.errorMessage = "Enter a valid server URL."
                        return
                    }
                    model.dismiss()
                    connect(url)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
