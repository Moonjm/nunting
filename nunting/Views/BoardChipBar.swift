import SwiftUI

struct BoardChipBar: View {
    let boards: [Board]
    @Binding var selection: Board?
    let onBrowseAll: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if boards.isEmpty {
                        Text("즐겨찾기한 보드가 없어요")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(boards) { board in
                            chip(for: board)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            Divider().frame(height: 22)

            Button(action: onBrowseAll) {
                Image(systemName: "line.3.horizontal")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("전체 보드 보기")
        }
        .padding(.vertical, 6)
    }

    private func chip(for board: Board) -> some View {
        let isSelected = selection == board
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = board
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(board.site.accentColor)
                    .frame(width: 6, height: 6)
                Text(board.name)
                    .font(.caption.weight(.medium))
            }
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

extension Site {
    var accentColor: Color {
        switch self {
        case .clien: .blue
        case .coolenjoy: .orange
        case .inven: .red
        case .ppomppu: .green
        }
    }
}
