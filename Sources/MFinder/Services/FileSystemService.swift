import Foundation
import AppKit
import UniformTypeIdentifiers

enum FileSystemError: Error {
    case accessDenied
    case notFound
}

final class FileSystemService {
    static let shared = FileSystemService()
    private let fm = FileManager.default
    private let workspace = NSWorkspace.shared

    // Icon caches — biggest perf win for the file list.
    // NSWorkspace.icon(forFile:) is an IPC round-trip; doing it per-file on
    // 1k+ directories takes hundreds of ms. Most files of the same extension
    // share an icon, so cache by extension.
    private var iconCacheByExt:    [String: NSImage] = [:]
    private var iconCacheByBundle: [String: NSImage] = [:]
    private lazy var folderIcon:   NSImage = Self.makeWindowsStyleFolderIcon()
    private lazy var fileIcon:     NSImage = workspace.icon(for: .data)
    private let iconCacheLock = NSLock()

    /// Windows-style yellow folder, drawn vector so it scales clean at any view-mode size.
    /// Uses SF Symbol `folder.fill` tinted with the same yellow the sidebar tree uses.
    private static func makeWindowsStyleFolderIcon() -> NSImage {
        let yellow = NSColor(red: 0.96, green: 0.78, blue: 0.18, alpha: 1.0)
        if let sym = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder") {
            let baseConfig  = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
            let colorConfig = NSImage.SymbolConfiguration(paletteColors: [yellow])
            if let tinted = sym.withSymbolConfiguration(baseConfig.applying(colorConfig)) {
                tinted.isTemplate = false
                return tinted
            }
        }
        return NSWorkspace.shared.icon(for: .folder)
    }

    func listContents(of url: URL, showHidden: Bool = false) throws -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions =
            showHidden ? [.skipsSubdirectoryDescendants]
                       : [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        let urls = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: options
        )
        return urls.compactMap { fileItem(from: $0) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func fileItem(from url: URL) -> FileItem? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .localizedTypeDescriptionKey, .nameKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDir = values.isDirectory ?? false
        return FileItem(
            id: url,
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: isDir,
            size: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate ?? Date(),
            creationDate: values.creationDate ?? Date(),
            typeDescription: values.localizedTypeDescription ?? (isDir ? "파일 폴더" : "파일"),
            icon: cachedIcon(for: url, isDirectory: isDir)
        )
    }

    /// Returns a 16x16 icon, cached per extension. App bundles get their own per-bundle icon.
    func cachedIcon(for url: URL, isDirectory: Bool) -> NSImage {
        if isDirectory {
            // .app is technically a directory but should use its own icon.
            let ext = url.pathExtension.lowercased()
            if ext == "app" {
                iconCacheLock.lock()
                if let cached = iconCacheByBundle[url.path] {
                    iconCacheLock.unlock()
                    return cached
                }
                iconCacheLock.unlock()
                let i = workspace.icon(forFile: url.path)
                iconCacheLock.lock()
                iconCacheByBundle[url.path] = i
                iconCacheLock.unlock()
                return i
            }
            return folderIcon
        }
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return fileIcon }
        iconCacheLock.lock()
        if let cached = iconCacheByExt[ext] {
            iconCacheLock.unlock()
            return cached
        }
        iconCacheLock.unlock()
        let i = workspace.icon(forFile: url.path)
        iconCacheLock.lock()
        iconCacheByExt[ext] = i
        iconCacheLock.unlock()
        return i
    }

    func openItem(_ url: URL) {
        workspace.open(url)
    }

    /// Result of resolving a URL through any symlinks / aliases. The caller
    /// decides whether to navigate (folder) or hand off to NSWorkspace (file).
    enum OpenAction {
        case navigate(URL)
        case openFile(URL)
        case broken(URL)   // dangling symlink / unresolvable alias
    }

    /// Resolves an item's URL through symlinks and Finder aliases and reports
    /// what double-click should do. So a shortcut pointing at a folder gets
    /// `navigate(target)` instead of `openFile(symlinkURL)` (which would let
    /// macOS hand the URL off to Finder).
    func openAction(for url: URL) -> OpenAction {
        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey, .isAliasFileKey, .isDirectoryKey
        ]
        let values = try? url.resourceValues(forKeys: keys)

        // Symbolic link → resolve via path, re-check type.
        if values?.isSymbolicLink == true {
            let resolved = url.resolvingSymlinksInPath()
            if let target = classify(resolved) {
                return target
            }
            return .broken(url)
        }

        // macOS Finder alias (bookmark-based) → resolve via URL initializer.
        if values?.isAliasFile == true {
            if let resolved = try? URL(resolvingAliasFileAt: url, options: []),
               let target = classify(resolved) {
                return target
            }
            return .broken(url)
        }

        // Plain item — use the URL's own type.
        if values?.isDirectory == true {
            return .navigate(url)
        }
        return .openFile(url)
    }

    /// Classifies a resolved URL as navigable (folder) or openable (file).
    /// Returns nil when the URL doesn't exist (broken link). The returned URL
    /// is standardized so it matches keys used by the sidebar tree cache.
    private func classify(_ url: URL) -> OpenAction? {
        let std = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: std.path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? .navigate(std) : .openFile(std)
    }

    func revealInFinder(_ url: URL) {
        workspace.activateFileViewerSelecting([url])
    }

    /// Moves a file/folder to the user's Trash by delegating to Finder via
    /// AppleScript. `FileManager.trashItem(at:)` silently unlinks files on
    /// macOS 26 for ad-hoc-signed apps — going through Finder ensures the
    /// move actually lands in ~/.Trash and is recoverable.
    func moveToTrash(_ url: URL) throws {
        try moveToTrashViaFinder([url])
    }

    /// Batch variant for moving multiple items at once with a single Finder
    /// round-trip. More efficient than calling moveToTrash N times.
    func moveToTrash(_ urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        try moveToTrashViaFinder(urls)
    }

    /// Empties the entire user Trash via Finder. Throws if Finder reports
    /// an error (e.g. permission denied or Trash already empty).
    func emptyTrash() throws {
        let script = """
            tell application "Finder"
                empty the trash
            end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "MFinder.Trash",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    stderr.isEmpty
                        ? "Finder가 휴지통 비우기를 거부했습니다."
                        : "Finder 오류: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"]
            )
        }
    }

    private func moveToTrashViaFinder(_ urls: [URL]) throws {
        // Build an AppleScript list of POSIX files like:
        //   {POSIX file "/path/one", POSIX file "/path/two"}
        let entries = urls.map { url -> String in
            let escaped = url.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "POSIX file \"\(escaped)\""
        }.joined(separator: ", ")

        let script = """
            tell application "Finder"
                move {\(entries)} to trash
            end tell
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do { try task.run() } catch {
            throw NSError(
                domain: "MFinder.Trash", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "osascript 실행 실패: \(error.localizedDescription)"]
            )
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            let msg = stderr.isEmpty
                ? "Finder가 휴지통 이동을 거부했습니다."
                : "Finder 오류: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            throw NSError(
                domain: "MFinder.Trash",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
    }

    func quickAccessLocations() -> [QuickAccessItem] {
        let home = fm.homeDirectoryForCurrentUser
        var items: [QuickAccessItem] = [
            QuickAccessItem(name: "바탕 화면",   url: home.appendingPathComponent("Desktop"),     systemSymbol: "menubar.dock.rectangle", isPinned: false),
            QuickAccessItem(name: "다운로드",     url: home.appendingPathComponent("Downloads"),   systemSymbol: "arrow.down.circle",      isPinned: false),
            QuickAccessItem(name: "문서",         url: home.appendingPathComponent("Documents"),   systemSymbol: "doc.text",               isPinned: false),
            QuickAccessItem(name: "사진",         url: home.appendingPathComponent("Pictures"),    systemSymbol: "photo",                  isPinned: false),
            QuickAccessItem(name: "음악",         url: home.appendingPathComponent("Music"),       systemSymbol: "music.note",             isPinned: false),
            QuickAccessItem(name: "동영상",       url: home.appendingPathComponent("Movies"),      systemSymbol: "film",                   isPinned: false)
        ]
        // Append user-pinned folders. Deduplicated against the built-ins above.
        let builtInPaths = Set(items.map { $0.url.standardizedFileURL.path })
        for url in PinnedFoldersService.shared.pinnedURLs {
            let std = url.standardizedFileURL
            guard !builtInPaths.contains(std.path) else { continue }
            items.append(QuickAccessItem(
                name: std.lastPathComponent.isEmpty ? std.path : std.lastPathComponent,
                url: std,
                systemSymbol: "pin.fill",
                isPinned: true
            ))
        }
        return items
    }

    func thisPCLocations() -> [QuickAccessItem] {
        let home = fm.homeDirectoryForCurrentUser
        var items: [QuickAccessItem] = [
            QuickAccessItem(name: "홈 (\(NSUserName()))", url: home, systemSymbol: "house"),
            QuickAccessItem(name: "응용 프로그램", url: URL(fileURLWithPath: "/Applications"), systemSymbol: "app.badge"),
            QuickAccessItem(name: "로컬 디스크 (C:)", url: URL(fileURLWithPath: "/"), systemSymbol: "internaldrive")
        ]
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for v in volumes where v.path != "/" {
            items.append(QuickAccessItem(name: v.lastPathComponent, url: v, systemSymbol: "externaldrive"))
        }
        return items
    }
}

struct QuickAccessItem: Identifiable, Hashable {
    var id: URL { url }
    let name: String
    let url: URL
    let systemSymbol: String
    var isPinned: Bool = false
}
