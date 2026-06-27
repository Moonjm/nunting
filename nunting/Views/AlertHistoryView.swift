import SwiftUI

/// 키워드 매칭으로 발송된 알림 이력. 서버가 매칭 시점에 기록한 것을
/// 최신순으로 보여주고, 행을 탭하면 푸시 탭과 동일하게 상세 overlay 로 진입.
/// 매칭/이력 기록은 전부 서버에서 일어나므로 여기선 읽기 전용으로 표시만 한다.
///
/// load()/markRead() 가 await 후 @State 를 갱신하므로 @MainActor 로 격리.
@MainActor
struct AlertHistoryView: View {
    /// 행 탭 시 시트를 닫고 상세 overlay 를 띄우기 위해 부모(KeywordListView)
    /// 시트의 dismiss 를 받는다.
    let onOpen: (URL, String) -> Void
    /// 안 읽음 개수가 바뀔 때마다 부모(탭 뱃지)에 알린다.
    var onUnreadCountChange: (Int) -> Void = { _ in }

    @State private var items: [AlertHistoryItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            if isLoading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if items.isEmpty {
                emptyState
                    .padding(.top, 60)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        Button { open(item) } label: { row(item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        // content 가 짧아도(빈 상태 포함) pull-to-refresh 가능하게.
        .scrollBounceBehavior(.always)
        .background(Color(.systemGroupedBackground))
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ item: AlertHistoryItem) -> some View {
        HStack(spacing: 10) {
            // 안 읽음 표시 점(Mail 스타일). 읽으면 자리만 유지해 정렬 흔들림 방지.
            Circle()
                .fill(item.read ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(item.read ? .regular : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(item.keyword)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    Text(Self.relative(item.sentDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("아직 받은 알림이 없어요", systemImage: "bell.slash")
        } description: {
            Text("구독한 키워드와 일치하는 새 글이 올라오면 여기에 쌓여요.")
        }
    }

    private func open(_ item: AlertHistoryItem) {
        guard let url = URL(string: item.url) else { return }
        markRead(item)
        onOpen(url, item.title)
    }

    /// "글을 열면 읽음" — 로컬 optimistic 갱신 + 서버 read_at set.
    private func markRead(_ item: AlertHistoryItem) {
        guard !item.read else { return }
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].read = true
        }
        onUnreadCountChange(items.filter { !$0.read }.count)
        // 서버 write 실패 시 optimistic 갱신을 되돌린다 — 안 그러면 로컬만
        // 읽음으로 갈라져, 다음 load() 가 다시 unread 로 끌어와 배지가 깜빡인다.
        // (KeywordListView 토글의 optimistic-revert 규율과 동일.)
        Task {
            do {
                try await AlertSubscriptionService.shared.markAlertRead(id: item.id)
            } catch {
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx].read = false
                }
                onUnreadCountChange(items.filter { !$0.read }.count)
            }
        }
    }

    private func load() async {
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await AlertSubscriptionService.shared.fetchAlertHistory()
            onUnreadCountChange(items.filter { !$0.read }.count)
        } catch {
            errorMessage = "알림 이력 불러오기 실패: \(error.localizedDescription)"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
