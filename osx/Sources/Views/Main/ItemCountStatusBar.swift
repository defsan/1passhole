import SwiftUI

/// Thin status bar pinned to the bottom of an item list, showing how many items it holds.
struct ItemCountStatusBar: View {
    let count: Int

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("\(count) \(count == 1 ? "Item" : "Items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}
