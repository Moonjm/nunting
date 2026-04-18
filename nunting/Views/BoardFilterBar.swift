import SwiftUI

struct BoardFilterBar: View {
    let filters: [BoardFilter]
    @Binding var selection: BoardFilter?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tab(label: "전체", isSelected: selection == nil) {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = nil }
                }
                ForEach(filters) { filter in
                    tab(label: filter.name, isSelected: selection?.id == filter.id) {
                        withAnimation(.easeInOut(duration: 0.15)) { selection = filter }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tab(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Color.accentColor : Color(uiColor: .systemBackground),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
