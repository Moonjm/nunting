import SwiftUI
import UserNotifications
import UIKit

/// 키워드 리스트 + 추가/삭제. 첫 키워드 추가 시 푸시 권한 요청.
/// 권한 거부 시 상단 배너로 안내(키워드 저장은 가능, 알림은 안 옴).
struct KeywordListView: View {
    /// 종 아이콘 시트의 두 탭: 키워드 관리 / 매칭된 알림 이력.
    private enum Tab: Hashable { case keywords, history }

    @Environment(\.dismiss) private var dismiss
    @Namespace private var tabNamespace
    @State private var tab: Tab = .keywords
    @State private var keywords: [String] = []
    @State private var newKeyword = ""
    @State private var errorMessage: String?
    @State private var pushAuthStatus: UNAuthorizationStatus = .notDetermined

    /// 삭제 confirm 대기 중인 키워드들. 비어있지 않으면 확인 alert 표시.
    /// 확정 전까지 실제 삭제는 하지 않는다(취소 시 복원 로직 불필요).
    @State private var pendingDeletion: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            tabSwitcher

            switch tab {
            case .keywords:
                keywordsList
            case .history:
                AlertHistoryView { url, title in
                    dismiss()
                    DetailOverlayController.shared.present(url: url, title: title)
                }
            }
        }
        .navigationTitle("알림")
        .navigationBarTitleDisplayMode(.inline)
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

    /// 키워드 / 받은 알림 전환 — 선택 캡슐이 스프링으로 슬라이딩하는 커스텀
    /// 세그먼트. 기본 `.segmented` Picker 보다 강조가 분명하고 부드럽다.
    private var tabSwitcher: some View {
        HStack(spacing: 4) {
            segment(.keywords, title: "키워드", icon: "tag.fill")
            segment(.history, title: "받은 알림", icon: "bell.fill")
        }
        .padding(4)
        .background(Capsule().fill(Color(.secondarySystemFill)))
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func segment(_ value: Tab, title: String, icon: String) -> some View {
        let selected = tab == value
        return Button {
            dismissKeyboard()
            withAnimation(.snappy(duration: 0.28)) { tab = value }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.semibold))
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(selected ? .white : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                if selected {
                    Capsule()
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "tabSelection", in: tabNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var keywordsList: some View {
        List {
            if pushAuthStatus == .denied {
                Section {
                    permissionBanner
                }
            }
            Section {
                HStack {
                    TextField("예: 삼다수, 500ml", text: $newKeyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            Task { await submitNewKeyword() }
                        }
                    Button("추가") {
                        dismissKeyboard()
                        Task { await submitNewKeyword() }
                    }
                    .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("새 키워드")
            } footer: {
                Text("콤마로 구분하면 모두 포함된 글만 알림 (예: 삼다수, 500ml)")
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
            Section("등록됨") {
                if keywords.isEmpty {
                    Text("아직 키워드가 없습니다").foregroundStyle(.secondary)
                } else {
                    ForEach(keywords, id: \.self) { kw in
                        HStack {
                            Text(kw)
                            Spacer()
                            Button {
                                dismissKeyboard()
                                pendingDeletion = [kw]
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("삭제: \(kw)")
                        }
                    }
                    .onDelete(perform: requestDeleteKeywords)
                }
            }
        }
    }

    /// 삭제 확인 alert 의 메시지. 단일/복수에 맞춰 문구 변경.
    private var deletePrompt: String {
        if pendingDeletion.count == 1 {
            return "'\(pendingDeletion[0])' 키워드를 삭제할까요?"
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

    private func loadAll() async {
        await refreshAuthStatus()
        do {
            keywords = try await AlertSubscriptionService.shared.listKeywords()
        } catch {
            errorMessage = "키워드 불러오기 실패: \(error.localizedDescription)"
        }
    }

    private func refreshAuthStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        pushAuthStatus = s.authorizationStatus
    }

    private func submitNewKeyword() async {
        let raw = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        errorMessage = nil

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

        do {
            let normalized = try await AlertSubscriptionService.shared.addKeyword(raw)
            newKeyword = ""
            if !keywords.contains(normalized) {
                keywords.append(normalized)
                keywords.sort()  // 서버도 정렬 응답
            }
        } catch {
            errorMessage = "추가 실패: \(error.localizedDescription)"
        }
    }

    /// 스와이프 삭제 — 즉시 지우지 않고 confirm 대기 목록에만 담는다.
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
    private func performDeletion(_ targets: [String]) async {
        keywords.removeAll { targets.contains($0) }
        var anyFailed = false
        for kw in targets {
            do {
                try await AlertSubscriptionService.shared.removeKeyword(kw)
            } catch {
                errorMessage = "삭제 실패(\(kw)): \(error.localizedDescription)"
                anyFailed = true
            }
        }
        if anyFailed {
            await loadAll()
        }
    }
}

#Preview {
    NavigationStack {
        KeywordListView()
    }
}
