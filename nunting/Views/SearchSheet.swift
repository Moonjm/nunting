import SwiftUI

struct SearchSheet: View {
    let board: Board
    let initialQuery: String
    let onSubmit: (String) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if board.supportsSearch {
                    Text("\(board.site.displayName) · \(board.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("검색어를 입력하세요", text: $query)
                            .textFieldStyle(.plain)
                            .submitLabel(.search)
                            .focused($focused)
                            .onSubmit(submit)
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color("AppSurface2"), in: RoundedRectangle(cornerRadius: 10))

                    if !initialQuery.isEmpty {
                        Button {
                            onClear()
                            dismiss()
                        } label: {
                            Label("검색 해제", systemImage: "arrow.uturn.left")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("이 보드는 검색을 지원하지 않습니다")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 24)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("검색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                if board.supportsSearch {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("검색", action: submit)
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            query = initialQuery
            if board.supportsSearch { focused = true }
        }
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}
