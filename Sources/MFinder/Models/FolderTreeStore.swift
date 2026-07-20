import Foundation
import SwiftUI

@MainActor
final class FolderTreeStore: ObservableObject {
    @Published private(set) var expandedURLs: Set<URL> = []
    @Published private(set) var childrenCache: [URL: [URL]] = [:]
    @Published private(set) var loadingURLs: Set<URL> = []

    /// Canonical directory-URL form used as the key everywhere in this store.
    /// `URL(fileURLWithPath: _, isDirectory: true)` ensures consistent trailing
    /// slash, so URLs from `contentsOfDirectory` (which mark directories) match
    /// URLs from `resolvingSymlinksInPath` (which don't).
    private func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    func isExpanded(_ url: URL) -> Bool {
        expandedURLs.contains(canonical(url))
    }

    func children(of url: URL) -> [URL]? {
        childrenCache[canonical(url)]
    }

    func toggle(_ url: URL) {
        let std = canonical(url)
        if expandedURLs.contains(std) {
            expandedURLs.remove(std)
        } else {
            expand(std)
        }
    }

    func expand(_ url: URL) {
        let std = canonical(url)
        // Idempotent — re-insert into a @Published Set still fires
        // objectWillChange and invalidates every row in the tree (a single
        // unnecessary one is enough to drop focus from an active inline
        // rename). Only mutate when state actually changes.
        if !expandedURLs.contains(std) {
            expandedURLs.insert(std)
        }
        if childrenCache[std] == nil {
            loadChildren(of: std)
        }
    }

    func collapse(_ url: URL) {
        expandedURLs.remove(canonical(url))
    }

    func reloadChildren(of url: URL) {
        let std = canonical(url)
        // Don't clobber the cache with nil first — that fires @Published twice
        // (nil, then real value) and invalidates every tree row before the
        // new data is ready, briefly tearing down any active inline rename.
        if expandedURLs.contains(std) {
            loadChildren(of: std)
        } else {
            childrenCache[std] = nil
        }
    }

    /// Walk up from `target`'s parent and expand each ancestor, so `target`
    /// becomes visible in the tree. Also forces hidden ancestors (e.g.
    /// `~/Library`) into their parent's children cache — otherwise the chain
    /// breaks because `loadChildren` defaults to skipping hidden files.
    ///
    /// Walking stops at the first sidebar root reached (see
    /// `FileSystemService.sidebarRootPaths()`), rather than continuing to `/`.
    /// A OneDrive folder lives at `~/Library/CloudStorage/OneDrive-…/`, which
    /// is reachable *both* from its 클라우드 root and from 내 PC → 홈 → Library.
    /// Expanding all the way up materializes that second chain, and since 내 PC
    /// sits above 클라우드 in the sidebar, the tree would then select the 내 PC
    /// copy and visibly drag the user out of the section they were browsing.
    func ensureVisible(_ target: URL, stoppingAt roots: Set<String> = []) {
        let targetURL = canonical(target)
        var current = targetURL.deletingLastPathComponent()
        var child = targetURL
        var safety = 0
        while safety < 64 {
            safety += 1
            expand(current)
            ensureChildIncluded(child, of: current)
            if roots.contains(current.standardizedFileURL.path) { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            child = current
            current = parent
        }
    }

    /// If `child` is a real folder but missing from `parent`'s children cache
    /// (because it's hidden), inject it so the tree can render the path chain.
    private func ensureChildIncluded(_ child: URL, of parent: URL) {
        let parentKey = canonical(parent)
        let childKey = canonical(child)
        guard var kids = childrenCache[parentKey] else { return }
        guard !kids.contains(childKey) else { return }
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: childKey.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        kids.append(childKey)
        kids.sort { a, b in
            a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
        }
        childrenCache[parentKey] = kids
    }

    private func loadChildren(of url: URL) {
        let std = canonical(url)
        loadingURLs.insert(std)
        defer { loadingURLs.remove(std) }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: std,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else {
            if childrenCache[std] != [] {
                childrenCache[std] = []
            }
            return
        }
        let folders = urls
            .filter { child in
                let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                let isDir = vals?.isDirectory ?? false
                let isPkg = vals?.isPackage ?? false
                return isDir && !isPkg
            }
            .sorted { a, b in
                a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
            }
            .map { canonical($0) }
        // Skip the @Published write if contents are byte-identical — file
        // watcher events fire frequently and most don't actually change the
        // children list; a no-op write still invalidates every row.
        if childrenCache[std] != folders {
            childrenCache[std] = folders
        }
    }
}
