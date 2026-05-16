import Foundation
import AppKit

/// Persists "Quick Access" pinned folders across launches.
/// Backed by UserDefaults so it survives quit/relaunch. Observable so the
/// sidebar refreshes immediately when items are added or removed.
final class PinnedFoldersService: ObservableObject, @unchecked Sendable {
    static let shared = PinnedFoldersService()

    private let key = "MFinder.pinnedFolders"
    private let defaults = UserDefaults.standard

    @Published private(set) var pinnedURLs: [URL] = []

    init() {
        load()
    }

    private func load() {
        let strings = defaults.array(forKey: key) as? [String] ?? []
        pinnedURLs = strings.compactMap { URL(string: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func save() {
        defaults.set(pinnedURLs.map { $0.absoluteString }, forKey: key)
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
}
