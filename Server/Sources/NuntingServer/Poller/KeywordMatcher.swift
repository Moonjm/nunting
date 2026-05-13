import NuntingCore

/// pure 매칭 함수 모음. Store 또는 APNs와 무관 — 단위 테스트가 가벼움.
///
/// 매칭 정규화: `post.title.lowercased()`와 `keyword`(이미
/// `Store.normalizedKeyword`를 통과해 lowercased + trimmed 상태) 사이의
/// `String.contains`. 한글은 lowercase가 no-op이지만 영문은 의미 있음.
enum KeywordMatcher {
    struct Match: Hashable {
        let post: Post
        let uuid: String
        let keyword: String
    }

    /// posts 순서를 보존. 한 post에 여러 (uuid, keyword) 매칭이 있으면 emit 여러 번.
    /// 같은 post 안에서는 (uuid 사전순, keyword 사전순)로 정렬해 결정적 순서 보장.
    static func match(
        posts: [Post],
        subscriptions: [String: Set<String>]
    ) -> [Match] {
        var out: [Match] = []
        for post in posts {
            let titleLower = post.title.lowercased()
            var perPost: [Match] = []
            for (uuid, keywords) in subscriptions {
                for keyword in keywords where titleLower.contains(keyword) {
                    perPost.append(Match(post: post, uuid: uuid, keyword: keyword))
                }
            }
            perPost.sort { lhs, rhs in
                if lhs.uuid != rhs.uuid { return lhs.uuid < rhs.uuid }
                return lhs.keyword < rhs.keyword
            }
            out.append(contentsOf: perPost)
        }
        return out
    }
}
