import Foundation
import SwiftUI

/// App-wide list of recently visited folders (most-recent first), persisted so
/// it survives relaunch. Surfaced in 이동 → 최근 폴더.
@MainActor
final class RecentsService: ObservableObject {
    static let shared = RecentsService()

    @Published private(set) var folders: [URL] = []

    private let key = "MFinder.recentFolders"
    private let maxCount = 15

    private init() {
        let paths = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        folders = paths.map { URL(fileURLWithPath: $0) }
    }

    func record(_ url: URL) {
        let std = url.standardizedFileURL
        folders.removeAll { $0.standardizedFileURL == std }
        folders.insert(std, at: 0)
        if folders.count > maxCount { folders = Array(folders.prefix(maxCount)) }
        UserDefaults.standard.set(folders.map(\.path), forKey: key)
    }

    func clear() {
        folders = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Menu content for 이동 → 최근 폴더. Posts `.mfinderNavigateTo` so ContentView
/// drives the active tab there.
struct RecentFoldersMenu: View {
    @ObservedObject private var recents = RecentsService.shared

    var body: some View {
        if recents.folders.isEmpty {
            Text(L("최근 폴더 없음"))
        } else {
            ForEach(recents.folders, id: \.self) { url in
                Button(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent) {
                    NotificationCenter.default.post(name: .mfinderNavigateTo, object: url)
                }
            }
            Divider()
            Button(L("목록 지우기")) { recents.clear() }
        }
    }
}
