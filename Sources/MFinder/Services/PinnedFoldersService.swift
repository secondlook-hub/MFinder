import Foundation
import AppKit

/// Persists "Quick Access" pinned folders across launches.
/// Backed by UserDefaults so it survives quit/relaunch. Observable so the
/// sidebar refreshes immediately when items are added or removed.
final class PinnedFoldersService: ObservableObject, @unchecked Sendable {
    static let shared = PinnedFoldersService()

    private let key = "MFinder.pinnedFolders"
    private let hiddenKey = "MFinder.hiddenBuiltinFavorites"
    private let defaults = UserDefaults.standard

    @Published private(set) var pinnedURLs: [URL] = []
    /// Standardized paths of BUILT-IN favorites (바탕 화면/다운로드/문서/사진/
    /// 음악/동영상) the user removed from the sidebar. Explorer-style: the
    /// defaults are removable too; the section's right-click menu restores.
    @Published private(set) var hiddenBuiltinPaths: Set<String> = []

    /// The six preset favorites quickAccessLocations() starts from.
    static var builtinFavoriteURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Downloads", "Documents", "Pictures", "Music", "Movies"]
            .map { home.appendingPathComponent($0) }
    }

    init() {
        load()
    }

    private func load() {
        let strings = defaults.array(forKey: key) as? [String] ?? []
        pinnedURLs = strings.compactMap { URL(string: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        hiddenBuiltinPaths = Set(defaults.stringArray(forKey: hiddenKey) ?? [])
    }

    private func save() {
        defaults.set(pinnedURLs.map { $0.absoluteString }, forKey: key)
        defaults.set(Array(hiddenBuiltinPaths), forKey: hiddenKey)
    }

    func pin(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        if !pinnedURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            pinnedURLs.append(url.standardizedFileURL)
            save()
        }
    }

    func pinMany(_ urls: [URL]) {
        for url in urls { pin(url) }
    }

    func unpin(_ url: URL) {
        pinnedURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        save()
    }

    func isPinned(_ url: URL) -> Bool {
        pinnedURLs.contains { $0.standardizedFileURL == url.standardizedFileURL }
    }

    // MARK: - Built-in favorites (hide/restore)

    func isBuiltinFavorite(_ url: URL) -> Bool {
        let std = url.standardizedFileURL.path
        return Self.builtinFavoriteURLs.contains { $0.standardizedFileURL.path == std }
    }

    func isBuiltinHidden(_ url: URL) -> Bool {
        hiddenBuiltinPaths.contains(url.standardizedFileURL.path)
    }

    /// True when the URL currently appears in the 즐겨찾기 section —
    /// a visible built-in or a user-pinned folder.
    func isInFavorites(_ url: URL) -> Bool {
        if isBuiltinFavorite(url) { return !isBuiltinHidden(url) }
        return isPinned(url)
    }

    /// 즐겨찾기에 추가: un-hides a removed built-in, pins anything else.
    func addToFavorites(_ url: URL) {
        if isBuiltinFavorite(url) {
            hiddenBuiltinPaths.remove(url.standardizedFileURL.path)
            save()
        } else {
            pin(url)
        }
    }

    /// 즐겨찾기에서 제거: hides a built-in, unpins anything else.
    func removeFromFavorites(_ url: URL) {
        if isBuiltinFavorite(url) {
            hiddenBuiltinPaths.insert(url.standardizedFileURL.path)
            save()
        } else {
            unpin(url)
        }
    }

    func restoreAllBuiltins() {
        hiddenBuiltinPaths.removeAll()
        save()
    }
}
