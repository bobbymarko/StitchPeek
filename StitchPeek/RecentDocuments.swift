import AppKit
import Observation

/// Open Recent, kept by the app itself.
///
/// `NSDocumentController.noteNewRecentDocumentURL` records nothing for a sandboxed app
/// with no `NSDocument` subclass — checked: nothing in the shared file list and no
/// `NSRecentDocumentRecords` in defaults. A plain URL would be no use after relaunch
/// anyway: the sandbox grants access to a user-opened file only for that session, and a
/// security-scoped bookmark is what carries the grant across launches.
@MainActor
@Observable
final class RecentDocuments {
    static let shared = RecentDocuments()

    private static let key = "recentDocumentBookmarks"
    private static let limit = 20

    /// Most recent first. Resolved from the bookmarks at launch.
    private(set) var urls: [URL] = []
    @ObservationIgnored private var bookmarks: [Data] = []

    private init() {
        reload()
    }

    func note(_ url: URL) {
        let url = url.standardizedFileURL

        // Already listed: move it to the front without minting another bookmark. A file
        // opened *from* this list may only be accessible through the bookmark it has.
        if let index = urls.firstIndex(of: url) {
            let bookmark = bookmarks.remove(at: index)
            urls.remove(at: index)
            bookmarks.insert(bookmark, at: 0)
            urls.insert(url, at: 0)
            save()
            return
        }

        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        bookmarks.insert(bookmark, at: 0)
        urls.insert(url, at: 0)
        if bookmarks.count > Self.limit {
            bookmarks.removeLast(bookmarks.count - Self.limit)
            urls.removeLast(urls.count - Self.limit)
        }
        save()
    }

    func clear() {
        bookmarks = []
        urls = []
        save()
    }

    private func reload() {
        let stored = UserDefaults.standard.array(forKey: Self.key) as? [Data] ?? []
        var keptBookmarks: [Data] = []
        var keptURLs: [URL] = []
        for data in stored {
            var isStale = false
            // A bookmark that no longer resolves (file deleted) is dropped. A stale one
            // still resolves — the file moved — and is kept as is.
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            keptBookmarks.append(data)
            keptURLs.append(url.standardizedFileURL)
        }
        bookmarks = keptBookmarks
        urls = keptURLs
        if keptBookmarks.count != stored.count { save() }
    }

    private func save() {
        UserDefaults.standard.set(bookmarks, forKey: Self.key)
    }
}
