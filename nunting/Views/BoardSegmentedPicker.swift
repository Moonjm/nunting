import SwiftUI

struct BoardSegmentedPicker: View {
    let boards: [Board]
    @Binding var selection: Board

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(boards) { board in
                    chip(for: board)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func chip(for board: Board) -> some View {
        let isSelected = selection == board
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = board
            }
        } label: {
            Text(board.name)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
