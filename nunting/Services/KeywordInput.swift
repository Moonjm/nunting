import Foundation

/// 키워드 입력 한 줄 ↔ (포함, 제외) 분리/복원. 한 행 = 한 입력 문자열이라
/// 추가·편집·표시가 같은 형식으로 통일된다.
///
/// 형식: 콤마로 토큰 구분, 토큰 앞에 `-` 가 붙으면 제외(앞의 `-` 1개만 플래그,
/// 중간 하이픈은 리터럴 — 예 `갤럭시-탭`). 포함은 AND, 제외는 OR.
/// 정규화(소문자/dedup/정렬)는 서버 책임 — 여기선 역할 분리만 한다.
// nonisolated: 순수 문자열 변환 — 기본 MainActor 격리 불필요(테스트가
// nonisolated 컨텍스트에서 직접 호출).
nonisolated enum KeywordInput {
    /// `"갤럭시, s24, -중고, -판매"` → (include: `"갤럭시,s24"`, exclude: `"중고,판매"`).
    /// 빈 토큰과 `-` 만 있는 토큰은 버린다.
    static func parse(_ raw: String) -> (include: String, exclude: String) {
        var include: [String] = []
        var exclude: [String] = []
        for part in raw.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if token.hasPrefix("-") {
                let body = String(token.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { exclude.append(body) }
            } else {
                include.append(token)
            }
        }
        return (include.joined(separator: ","), exclude.joined(separator: ","))
    }

    /// (포함, 제외) → 편집용 단일 입력 문자열. 행을 탭해 재편집할 때 입력칸을
    /// 채운다. 제외 토큰엔 `-` 접두를 다시 붙인다.
    /// `("갤럭시,s24", "중고,판매")` → `"갤럭시, s24, -중고, -판매"`.
    static func compose(keyword: String, exclude: String) -> String {
        let inc = keyword.split(separator: ",").map(String.init)
        let exc = exclude.split(separator: ",").map { "-" + $0 }
        return (inc + exc).joined(separator: ", ")
    }
}
