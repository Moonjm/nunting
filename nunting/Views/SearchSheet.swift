import SwiftUI
struct SearchSheet: View {
    let board: Board
    let initialQuery: String
    let onSubmit: (String) -> Void

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
            }
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
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
        // 검색 필드가 차지하는 만큼만 — 키보드가 올라오면 그 위에 딱 붙어
        // 빈 공간이 거의 없게. (해제는 탭바 X 버튼이 담당 → 시트엔 필드만)
        // 검색 필드+키패드만(152) 고정 — 다중 detent 면 키보드 등장 시 큰
        // detent 로 점프해 필드~키보드 사이가 다시 벌어진다. 단일로 유지.
        .presentationDetents([.height(152)])
        .presentationDragIndicator(.visible)
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
