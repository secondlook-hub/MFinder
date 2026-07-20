import Foundation
import SwiftUI

/// Which sidebar section a branch belongs to. Part of a branch's identity
/// because the root URL alone doesn't separate sections: pinning a cloud
/// provider to 즐겨찾기 puts the *same* directory at the top of two sections.
enum SidebarBranchKind: String, Hashable {
    case favorites, thisPC, cloud
}

/// One top-level sidebar row and everything under it.
struct TreeBranch: Hashable {
    let kind: SidebarBranchKind
    let root: URL

    init(kind: SidebarBranchKind, root: URL) {
        self.kind = kind
        self.root = URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true)
    }
}

/// Identity of one row in the sidebar tree: a folder *as reached through a
/// particular branch*.
///
/// The same directory can appear in more than one place — `~/Desktop` is both
/// 즐겨찾기 → 바탕 화면 and 내 PC → 홈 → Desktop, and a 클라우드 root added to
/// 즐겨찾기 shows up twice at the same path. Keying expansion by URL alone made
/// those rows share one flag, so expanding either expanded both, and AppKit
/// (which compares sidebar items by value) resolved `row(forItem:)` to
/// whichever came first in display order — scrolling the tree up to 즐겨찾기
/// while the user was working down in 내 PC.
struct TreeNode: Hashable {
    let branch: TreeBranch
    let url: URL

    /// The URL is canonicalized on the way in, so a node built from
    /// `contentsOfDirectory` output matches one built from a resolved path.
    init(branch: TreeBranch, url: URL) {
        self.branch = branch
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }
}

@MainActor
final class FolderTreeStore: ObservableObject {
    /// Per-branch expansion — the authority for what the sidebar draws.
    @Published private(set) var expandedNodes: Set<TreeNode> = []
    /// Every distinct URL in `expandedNodes`, kept in sync on each mutation.
    /// The FSEvents watch set and `reloadChildren` are branch-agnostic: one
    /// directory is watched once no matter how many rows show it.
    @Published private(set) var expandedURLs: Set<URL> = []
    @Published private(set) var childrenCache: [URL: [URL]] = [:]
    @Published private(set) var loadingURLs: Set<URL> = []

    /// Branch the user is currently working in, set by the sidebar when its
    /// selection changes. A reveal prefers this branch whenever the target
    /// lives under it, so walking deeper from 내 PC → 홈 → Desktop grows *that*
    /// branch instead of jumping to the 즐겨찾기 copy of the same folder.
    var activeBranch: TreeBranch?

    /// Canonical directory-URL form used as the key everywhere in this store.
    /// `URL(fileURLWithPath: _, isDirectory: true)` ensures consistent trailing
    /// slash, so URLs from `contentsOfDirectory` (which mark directories) match
    /// URLs from `resolvingSymlinksInPath` (which don't).
    private func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    /// True when *any* branch shows this directory expanded — the question the
    /// file-system watcher asks.
    func isExpanded(_ url: URL) -> Bool {
        expandedURLs.contains(canonical(url))
    }

    func isExpanded(_ node: TreeNode) -> Bool {
        expandedNodes.contains(node)
    }

    func children(of url: URL) -> [URL]? {
        childrenCache[canonical(url)]
    }

    func toggle(_ node: TreeNode) {
        if expandedNodes.contains(node) {
            collapse(node)
        } else {
            expand(node)
        }
    }

    func expand(_ node: TreeNode) {
        // Idempotent — re-insert into a @Published Set still fires
        // objectWillChange and invalidates every row in the tree (a single
        // unnecessary one is enough to drop focus from an active inline
        // rename). Only mutate when state actually changes.
        if !expandedNodes.contains(node) {
            expandedNodes.insert(node)
            syncExpandedURLs()
        }
        if childrenCache[node.url] == nil {
            loadChildren(of: node.url)
        }
    }

    func collapse(_ node: TreeNode) {
        guard expandedNodes.remove(node) != nil else { return }
        syncExpandedURLs()
    }

    private func syncExpandedURLs() {
        let urls = Set(expandedNodes.map(\.url))
        if expandedURLs != urls {
            expandedURLs = urls
        }
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
    /// The walk happens inside exactly one branch and stops at that branch's
    /// root, rather than continuing to `/`. Which branch is decided by
    /// `revealBranch(for:)`: the one the user is already working in when the
    /// target lives under it, otherwise the most specific sidebar root that
    /// contains it. Expanding all the way to `/` would materialize the folder's
    /// *other* home (a OneDrive folder is reachable both from its 클라우드 root
    /// and via 내 PC → 홈 → Library) and drag the tree out of the section the
    /// user was browsing.
    ///
    /// A target that is itself a root needs no reveal — it already has a
    /// top-level row.
    func ensureVisible(_ target: URL) {
        let targetURL = canonical(target)
        guard let branch = revealBranch(for: targetURL),
              branch.root.path != targetURL.path else { return }
        var current = targetURL.deletingLastPathComponent()
        var child = targetURL
        var safety = 0
        while safety < 64 {
            safety += 1
            expand(TreeNode(branch: branch, url: current))
            ensureChildIncluded(child, of: current)
            if current.path == branch.root.path { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            child = current
            current = parent
        }
    }

    /// Branch to reveal `target` in. Prefers `activeBranch` so a reveal never
    /// yanks the user into a different section showing the same folder.
    private func revealBranch(for target: URL) -> TreeBranch? {
        if let active = activeBranch, contains(active.root, target) {
            return active
        }
        return FileSystemService.shared.sidebarBranch(for: target)
    }

    private func contains(_ root: URL, _ target: URL) -> Bool {
        let rootPath = root.path
        let targetPath = target.path
        if rootPath == targetPath { return true }
        return targetPath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
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
