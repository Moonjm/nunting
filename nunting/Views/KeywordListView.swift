import SwiftUI
import UserNotifications
import UIKit

/// 키워드 리스트 + 추가/삭제. 첫 키워드 추가 시 푸시 권한 요청.
/// 권한 거부 시 상단 배너로 안내(키워드 저장은 가능, 알림은 안 옴).
struct KeywordListView: View {
    @State private var keywords: [String] = []
    @State private var newKeyword = ""
    @State private var errorMessage: String?
    @State private var pushAuthStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
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
                        .onSubmit { Task { await submitNewKeyword() } }
                    Button("추가") { Task { await submitNewKeyword() } }
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
                                Task { await removeSingle(kw) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("삭제: \(kw)")
                        }
                    }
                    .onDelete(perform: deleteKeywords)
                }
            }
        }
        .navigationTitle("알림 키워드")
        .task { await loadAll() }
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

    private func deleteKeywords(at offsets: IndexSet) {
        let toDelete = offsets.map { keywords[$0] }
        keywords.remove(atOffsets: offsets)
        Task {
            var anyFailed = false
            for kw in toDelete {
                do {
                    try await AlertSubscriptionService.shared.removeKeyword(kw)
                } catch {
                    errorMessage = "삭제 실패(\(kw)): \(error.localizedDescription)"
                    anyFailed = true
                }
            }
            // 실패한 항목이 optimistic remove로 사라진 채 보이지 않게, 서버 상태로
            // resync. 성공 case는 no-op(서버도 이미 삭제 반영).
            if anyFailed {
                await loadAll()
            }
        }
    }

    /// 명시 삭제 버튼(빨간 minus.circle) 탭 시 — 단일 키워드 즉시 optimistic 제거.
    /// 서버 fail 시 loadAll로 resync해 사라진 항목 복원.
    private func removeSingle(_ kw: String) async {
        keywords.removeAll { $0 == kw }
        do {
            try await AlertSubscriptionService.shared.removeKeyword(kw)
        } catch {
            errorMessage = "삭제 실패(\(kw)): \(error.localizedDescription)"
            await loadAll()
        }
    }
}

#Preview {
    NavigationStack {
        KeywordListView()
    }
}
