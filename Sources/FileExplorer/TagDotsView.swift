import SwiftUI
import FileExplorerCore

/// Finder-style colored tag dots. Standard label names map to their colors;
/// unknown tags render gray. Dots overlap slightly like Finder's.
struct TagDotsView: View {
    let tags: [String]

    static func color(for tag: String) -> Color {
        switch tag {
        case "Red": .red
        case "Orange": .orange
        case "Yellow": .yellow
        case "Green": .green
        case "Blue": .blue
        case "Purple": .purple
        case "Gray", "Grey": .gray
        default: .gray
        }
    }

    var body: some View {
        HStack(spacing: -3) {
            ForEach(tags.prefix(3), id: \.self) { tag in
                Circle()
                    .fill(Self.color(for: tag))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1))
            }
        }
        .help(tags.joined(separator: ", "))
    }
}
