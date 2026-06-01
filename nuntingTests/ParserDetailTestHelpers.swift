import CoreGraphics
import Foundation
import XCTest
@testable import nunting

// MARK: - ContentBlock extraction

extension Array where Element == ContentBlock {
    /// `(url, posterURL?)` for every `.video` block, in document order.
    var videos: [(URL, URL?)] {
        compactMap { block -> (URL, URL?)? in
            if case .video(let url, let posterURL) = block.kind {
                return (url, posterURL)
            }
            return nil
        }
    }

    /// `url` for every `.video` block (poster discarded).
    var videoURLs: [URL] { videos.map(\.0) }

    /// `(url, aspectRatio?)` for every `.image` block.
    var images: [(URL, CGFloat?)] {
        compactMap { block -> (URL, CGFloat?)? in
            if case .image(let url, _, let aspectRatio) = block.kind {
                return (url, aspectRatio)
            }
            return nil
        }
    }

    /// `url` for every `.image` block (aspect ratio discarded).
    var imageURLs: [URL] { images.map(\.0) }

    /// `(provider, id)` for every `.embed` block.
    var embeds: [(EmbedProvider, String)] {
        compactMap { block -> (EmbedProvider, String)? in
            if case .embed(let provider, let id) = block.kind {
                return (provider, id)
            }
            return nil
        }
    }

    /// IDs of every `.embed(provider: .youtube, id:)` block — shortcut for
    /// the common test of "did the parser surface this YouTube iframe?".
    var youtubeIDs: [String] {
        embeds.compactMap { $0.0 == .youtube ? $0.1 : nil }
    }

    /// `(url, label)` for every `.dealLink` block.
    var dealLinks: [(URL, String)] {
        compactMap { block -> (URL, String)? in
            if case .dealLink(let url, let label) = block.kind {
                return (url, label)
            }
            return nil
        }
    }

    /// All inline segments across every `.richText` block, in document order.
    /// Use as the entry point for text/link queries that span the whole body.
    var richTextSegments: [InlineSegment] {
        flatMap { block -> [InlineSegment] in
            if case .richText(let segs) = block.kind { return segs }
            return []
        }
    }

    /// Joined plain text across every `.richText` block (link segments dropped).
    /// Shortcut for `richTextSegments.plainText`.
    var plainText: String { richTextSegments.plainText }

    /// One entry per `.richText` block; each entry = that block's `.text`
    /// segments concatenated. Use when per-block grouping matters
    /// (e.g. "head block contains X but tail block doesn't").
    var blockTexts: [String] {
        compactMap { block -> String? in
            if case .richText(let segs) = block.kind { return segs.plainText }
            return nil
        }
    }

    /// `(url, label)` for every `.link` segment across `.richText` blocks.
    var links: [(URL, String)] { richTextSegments.links }
}

// MARK: - InlineSegment extraction

extension Array where Element == InlineSegment {
    /// Joined `.text` segments (drops `.link` segments).
    var plainText: String { textSegments.joined() }

    /// Plain text segments only.
    var textSegments: [String] {
        compactMap { seg in
            if case .text(let s) = seg { return s }
            return nil
        }
    }

    /// `(url, label)` for every `.link` segment.
    var links: [(URL, String)] {
        compactMap { seg in
            if case .link(let url, let label) = seg { return (url, label) }
            return nil
        }
    }
}

// MARK: - Post fixture

extension Post {
    /// Test fixture with required fields defaulted. Override only what the
    /// test cares about — most parser detail tests only need `site` + `url`.
    /// All-default invocation (`Post.fixture()`) returns a valid Post for
    /// parsers that don't inspect the post itself (only its URL host /
    /// site enum).
    static func fixture(
        id: String = "test-post-id",
        site: Site = .clien,
        boardID: String = "test-board",
        title: String = "테스트",
        author: String = "테스터",
        date: Date? = nil,
        dateText: String = "방금",
        commentCount: Int = 0,
        url: URL = URL(string: "https://example.com/test")!,
        viewCount: Int? = nil,
        recommendCount: Int? = nil,
        levelText: String? = nil,
        hasAuthIcon: Bool = false
    ) -> Post {
        Post(
            id: id,
            site: site,
            boardID: boardID,
            title: title,
            author: author,
            date: date,
            dateText: dateText,
            commentCount: commentCount,
            url: url,
            viewCount: viewCount,
            recommendCount: recommendCount,
            levelText: levelText,
            hasAuthIcon: hasAuthIcon
        )
    }
}
