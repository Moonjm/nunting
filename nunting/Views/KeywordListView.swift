import SwiftUI
import UserNotifications
import UIKit

/// 키워드 리스트 + 추가/삭제. 첫 키워드 추가 시 푸시 권한 요청.
/// 권한 거부 시 상단 배너로 안내(키워드 저장은 가능, 알림은 안 옴).
///
/// async 메서드(loadAll/submitNewKeyword/performDeletion)가 await 후 @State 를
/// 만지므로 뷰 전체를 @MainActor 로 격리해 메인 스레드 갱신을 보장.
@MainActor
struct KeywordListView: View {
    /// 종 아이콘 시트의 두 탭: 키워드 관리 / 매칭된 알림 이력.
    private enum Tab: Hashable { case keywords, history }

    @Environment(\.dismiss) private var dismiss
    @Namespace private var tabNamespace
    @State private var tab: Tab = .keywords
    @State private var keywords: [KeywordSub] = []
    @State private var newKeyword = ""
    @State private var errorMessage: String?
    @State private var pushAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var unreadCount = 0
    @FocusState private var inputFocused: Bool

    /// 편집 중인 행의 원래 포함 키워드(PK). nil = 신규 추가. 편집 저장 시
    /// 포함이 바뀌어 PK가 달라지면 이 값으로 이전 행을 지운다.
    @State private var editingOriginal: String?

    /// 삭제 confirm 대기 중인 키워드들. 비어있지 않으면 확인 alert 표시.
    /// 확정 전까지 실제 삭제는 하지 않는다(취소 시 복원 로직 불필요).
    @State private var pendingDeletion: [KeywordSub] = []

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            switch tab {
            case .keywords:
                keywordsList
            case .history:
                AlertHistoryView(
                    onOpen: { url, title in
                        dismiss()
                        DetailOverlayController.shared.present(url: url, title: title)
                    },
                    onUnreadCountChange: { unreadCount = $0 }
                )
            }
        }
        .navigationTitle("알림")
        .navigationBarTitleDisplayMode(.inline)
        .dismissKeyboardOnBackgroundTap()
        .task { await loadAll() }
        .alert("키워드 삭제", isPresented: deleteConfirmBinding) {
            Button("삭제", role: .destructive) {
                let targets = pendingDeletion
                pendingDeletion = []
                Task { await performDeletion(targets) }
            }
            Button("취소", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(deletePrompt)
        }
    }

    // MARK: - 상단 언더라인 탭

    /// 선택된 탭 라벨 아래 2pt 인디케이터가 슬라이딩하는 상단 탭바
    /// (Threads/App Store 스타일). 좌측 정렬 + 하단 헤어라인.
    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.keywords, "키워드")
            tabButton(.history, "받은 알림")
        }
        .padding(.top, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tabButton(_ value: Tab, _ title: String) -> some View {
        let selected = tab == value
        // 밑줄(overlay)을 라벨에 붙여 폭 = 라벨 폭 으로 고정한 뒤, 바깥 frame 으로
        // 각 탭을 50% 폭에 중앙 배치 → 라벨·밑줄이 가운데 정렬(App Store/Music 느낌).
        return HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            if value == .history && unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
            }
        }
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            if selected {
                Capsule()
                    .fill(.tint)
                    .frame(height: 2)
                    .matchedGeometryEffect(id: "tabUnderline", in: tabNamespace)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            dismissKeyboard()
            withAnimation(.snappy(duration: 0.2)) { tab = value }
        }
    }

    // MARK: - 키워드 탭

    private var keywordsList: some View {
        List {
            if pushAuthStatus == .denied {
                Section { permissionBanner }
            }

            Section {
                HStack(spacing: 8) {
                    TextField("예: 갤럭시, -중고", text: $newKeyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .focused($inputFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            Task { await submitNewKeyword() }
                        }
                    // 상시 노출(액션 포인트 명확) — 빈칸이면 비활성 회색. Return 으로도 등록.
                    Button(editingOriginal == nil ? "추가" : "저장") {
                        dismissKeyboard()
                        Task { await submitNewKeyword() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(trimmedNewKeyword.isEmpty)
                }
            } header: {
                Text(editingOriginal == nil ? "키워드 추가" : "키워드 편집")
            } footer: {
                Text("쉼표로 구분하면 모두 포함된 글만 알려드려요. 단어 앞에 -를 붙이면 제외돼요. 예: 갤럭시, -중고, -판매")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }

            Section {
                if keywords.isEmpty {
                    Text("등록된 키워드가 없어요")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(keywords) { kw in
                        TokenRow(
                            includeTokens: tokens(of: kw.keyword),
                            excludeTokens: tokens(of: kw.exclude)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { beginEdit(kw) }
                    }
                    .onDelete(perform: requestDeleteKeywords)
                }
            } header: {
                Text(keywords.isEmpty ? "등록된 키워드" : "등록된 키워드 \(keywords.count)")
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - 파생값

    private var trimmedNewKeyword: String {
        newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 정규화된 CSV 키워드를 AND 토큰 배열로. "355ml,제로" → ["355ml", "제로"].
    private func tokens(of keyword: String) -> [String] {
        keyword.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 삭제 확인 alert 의 메시지. 단일/복수에 맞춰 문구 변경.
    private var deletePrompt: String {
        if pendingDeletion.count == 1 {
            return "'\(pendingDeletion[0].keyword)' 키워드를 삭제할까요?"
        }
        return "키워드 \(pendingDeletion.count)개를 삭제할까요?"
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeletion.isEmpty },
            set: { if !$0 { pendingDeletion = [] } }
        )
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("푸시 알림 권한이 꺼져 있습니다")
                .font(.subheadline.weight(.semibold))
            Text("키워드가 매칭돼도 알림이 도착하지 않습니다. 설정에서 켜주세요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 동작

    private func loadAll() async {
        await refreshAuthStatus()
        do {
            keywords = try await AlertSubscriptionService.shared.listKeywords()
        } catch {
            errorMessage = "키워드 불러오기 실패: \(error.localizedDescription)"
        }
        // 히스토리 탭에 들어가기 전에도 안 읽음 뱃지가 보이게 개수만 미리 조회.
        // AlertHistoryView 진입 시 한 번 더 fetch 되지만(이중 호출), 1인·수백 행
        // 규모라 비용이 무시할 만해 별도 count 엔드포인트는 두지 않는다. 더 최신인
        // 쪽이 onUnreadCountChange 로 badge 를 덮어써 일관성도 자연히 수렴.
        if let history = try? await AlertSubscriptionService.shared.fetchAlertHistory() {
            unreadCount = history.filter { !$0.read }.count
        }
    }

    private func refreshAuthStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        pushAuthStatus = s.authorizationStatus
    }

    /// 행을 탭하면 그 행을 단일 입력 문자열로 복원해 입력칸을 편집 모드로.
    /// 저장 시 포함이 바뀌면 editingOriginal 로 이전 행을 지운다.
    private func beginEdit(_ kw: KeywordSub) {
        errorMessage = nil
        editingOriginal = kw.keyword
        newKeyword = KeywordInput.compose(keyword: kw.keyword, exclude: kw.exclude)
        inputFocused = true
    }

    private func submitNewKeyword() async {
        let raw = trimmedNewKeyword
        guard !raw.isEmpty else { return }
        errorMessage = nil

        // 입력 한 줄 → (포함, 제외) 분리. 포함이 하나도 없으면(전부 -단어) 거부.
        let parsed = KeywordInput.parse(raw)
        guard !parsed.include.isEmpty else {
            errorMessage = "포함할 키워드를 최소 하나 입력하세요. (앞에 -는 제외 단어)"
            return
        }

        // 첫 키워드 추가 시 푸시 권한 요청. 이미 결정된 상태면 no-op.
        if pushAuthStatus == .notDetermined {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            await refreshAuthStatus()
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }

        let original = editingOriginal
        do {
            let sub = try await AlertSubscriptionService.shared.upsertKeyword(
                keyword: parsed.include, exclude: parsed.exclude)
            newKeyword = ""
            editingOriginal = nil
            inputFocused = false
            // 편집 중 포함이 바뀌어 PK(=keyword)가 달라졌으면 이전 행 제거.
            // 삭제 실패 시: 새 행 upsert 는 이미 됐지만 옛 행이 서버에 남아
            // 다음 loadAll 에서 되살아난다(둘 다 보임). performDeletion 과 같은
            // 규율로 에러 표시 + 즉시 resync 해 로컬/서버 상태를 맞춘다.
            if let original, original != sub.keyword {
                do {
                    try await AlertSubscriptionService.shared.removeKeyword(original)
                    keywords.removeAll { $0.keyword == original }
                } catch {
                    errorMessage = "이전 키워드 삭제 실패: \(error.localizedDescription)"
                    await loadAll()
                    return
                }
            }
            // upsert 결과로 로컬 행 교체(신규/제외갱신 모두 커버) 후 정렬.
            keywords.removeAll { $0.keyword == sub.keyword }
            keywords.append(sub)
            keywords.sort { $0.keyword < $1.keyword }  // 서버도 keyword 정렬 응답
        } catch {
            errorMessage = "저장 실패: \(error.localizedDescription)"
        }
    }

    /// 스와이프/편집 삭제 — 즉시 지우지 않고 confirm 대기 목록에만 담는다.
    /// 실제 제거는 확인 alert 의 "삭제" 확정 후 performDeletion 에서.
    private func requestDeleteKeywords(at offsets: IndexSet) {
        dismissKeyboard()
        pendingDeletion = offsets.map { keywords[$0] }
    }

    /// 올라와 있는 키보드를 내린다. 추가/삭제 액션 직전에 호출해 alert 가
    /// 키보드 위로 어색하게 겹쳐 뜨지 않게 한다.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// confirm 확정 후 호출 — optimistic 제거 + 서버 삭제. 서버 fail 시
    /// loadAll 로 resync 해 사라진 항목 복원.
    private func performDeletion(_ targets: [KeywordSub]) async {
        let ids = Set(targets.map(\.keyword))
        // 편집 중인 행이 삭제 대상에 포함되면 편집 상태를 비운다. 안 그러면
        // 삭제 후에도 입력창에 그 행이 남아 "저장" 시 방금 지운 행이 되살아난다.
        if let editingOriginal, ids.contains(editingOriginal) {
            self.editingOriginal = nil
            newKeyword = ""
            inputFocused = false
        }
        keywords.removeAll { ids.contains($0.keyword) }
        var anyFailed = false
        for t in targets {
            do {
                try await AlertSubscriptionService.shared.removeKeyword(t.keyword)
            } catch {
                errorMessage = "삭제 실패(\(t.keyword)): \(error.localizedDescription)"
                anyFailed = true
            }
        }
        if anyFailed {
            await loadAll()
        }
    }
}

/// 한 구독 행을 토큰 칩 묶음으로 렌더. 포함 칩(AND)은 기본 회색 배경, 제외
/// 칩(OR)은 같은 줄에 이어 붙되 **배경색만 빨강 계열**로 구분한다(라벨/구분자
/// 없이 색으로만). 토큰이 많아 행 폭을 넘으면 FlowLayout 이 다음 줄로 흘린다.
private struct TokenRow: View {
    let includeTokens: [String]
    let excludeTokens: [String]

    var body: some View {
        FlowLayout(hSpacing: 6, vSpacing: 6) {
            ForEach(Array(includeTokens.enumerated()), id: \.offset) { _, token in
                // 시각은 배경색으로만 구분(설계대로). 색을 못 보는 VoiceOver
                // 사용자를 위해 포함/제외 역할은 접근성 레이블로만 덧붙인다.
                chip(token, background: Color(.secondarySystemFill))
                    .accessibilityLabel("포함 \(token)")
            }
            ForEach(Array(excludeTokens.enumerated()), id: \.offset) { _, token in
                chip(token, background: Color.red.opacity(0.18))
                    .accessibilityLabel("제외 \(token)")
            }
        }
        .padding(.vertical, 2)
    }

    private func chip(_ token: String, background: Color) -> some View {
        Text(token)
            .font(.subheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }
}

/// 자식 뷰를 좌→우로 배치하다 폭을 넘으면 다음 줄로 wrap 하는 단순 flow 레이아웃.
/// 칩(토큰)이 많은 AND 키워드가 한 줄을 넘겨도 잘리지 않게 한다.
private struct FlowLayout: Layout {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - hSpacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    NavigationStack {
        KeywordListView()
    }
}
