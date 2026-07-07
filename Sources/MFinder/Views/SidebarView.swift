import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// SwiftUI host for the NSOutlineView-based sidebar. The actual rendering
/// lives in `SidebarOutlineRepresentable` so inline rename can use AppKit's
/// `editColumn` field-editor mechanism (matching FileTableView), avoiding the
/// SwiftUI gesture/menu focus races we hit when wrapping NSTextField in
/// NSViewRepresentable per-row.
struct SidebarView: View {
    @EnvironmentObject var nav: NavigationState
    @EnvironmentObject var tree: FolderTreeStore
    @ObservedObject private var themes = ThemeService.shared

    /// Operative URLs for sidebar keyboard shortcuts — the multi-selection
    /// if non-empty, otherwise the currently-navigated folder. This is how
    /// Cmd+C / Cmd+X / ⌘⌫ pick up a user's Cmd-/Shift-click selection.
    private var sidebarActionURLs: [URL] {
        nav.sidebarSelectionURLs.isEmpty ? [nav.currentURL] : nav.sidebarSelectionURLs
    }

    var body: some View {
        SidebarOutlineRepresentable(nav: nav, tree: tree)
            .background(themes.theme.contentBackground.color)
            .onReceive(NotificationCenter.default.publisher(for: .mfinderRenameSelected)) { _ in
                guard AppFocus.area == .sidebar else { return }
                guard nav.renamingURL == nil else { return }
                // Rename is single-row only; prefer first selected, fall
                // back to current folder.
                nav.renamingURL = nav.sidebarSelectionURLs.first ?? nav.currentURL
            }
            .onReceive(NotificationCenter.default.publisher(for: .mfinderTrashSelected)) { _ in
                guard AppFocus.area == .sidebar else { return }
                trashTreeFolders(sidebarActionURLs, nav: nav, tree: tree)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mfinderTreeCopy)) { _ in
                guard AppFocus.area == .sidebar else { return }
                ClipboardService.shared.copy(sidebarActionURLs)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mfinderTreeCut)) { _ in
                guard AppFocus.area == .sidebar else { return }
                ClipboardService.shared.cut(sidebarActionURLs)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mfinderTreePaste)) { _ in
                guard AppFocus.area == .sidebar else { return }
                // Paste destination is single — the currently-shown folder.
                pasteIntoFolderShared(nav.currentURL, nav: nav, tree: tree)
            }
    }
}

// MARK: - Tree folder rename / trash (shared between context menu and the
// sidebar's global F2 / ⌘⌫ keyboard listener)

@MainActor
func promptRenameTreeFolder(_ folder: URL, nav: NavigationState, tree: FolderTreeStore) {
    let alert = NSAlert()
    alert.messageText = "폴더 이름 바꾸기"
    alert.informativeText = "새 이름을 입력하세요."
    alert.addButton(withTitle: "확인")
    alert.addButton(withTitle: "취소")
    let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    tf.stringValue = folder.lastPathComponent
    alert.accessoryView = tf
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newName.isEmpty, newName != folder.lastPathComponent else { return }
    let dst = folder.deletingLastPathComponent().appendingPathComponent(newName)
    do {
        try FileManager.default.moveItem(at: folder, to: dst)
        UndoService.shared.register(.move(pairs: [(from: folder, to: dst)]), label: "이름 바꾸기")
        tree.reloadChildren(of: folder.deletingLastPathComponent())
        if folder.standardizedFileURL == nav.currentURL.standardizedFileURL {
            nav.navigate(to: dst)
        }
    } catch {
        showTreeAlert("이름 바꾸기 실패", error.localizedDescription)
    }
}

@MainActor
func trashTreeFolders(_ folders: [URL], nav: NavigationState, tree: FolderTreeStore) {
    guard !folders.isEmpty else { return }
    if folders.count == 1 {
        trashTreeFolder(folders[0], nav: nav, tree: tree)
        return
    }
    let alert = NSAlert()
    alert.messageText = "\(folders.count)개 폴더를 휴지통으로 보내시겠습니까?"
    alert.informativeText = "선택한 폴더와 그 안의 모든 내용이 휴지통으로 이동됩니다."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "휴지통으로")
    alert.addButton(withTitle: "취소")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    var firstErr: Error?
    var trashed: [URL] = []
    for folder in folders {
        do {
            try FileSystemService.shared.moveToTrash(folder)
            trashed.append(folder)
        } catch {
            if firstErr == nil { firstErr = error }
        }
    }
    UndoService.shared.register(.trash(originals: trashed), label: "휴지통으로 이동")
    let parents = Set(folders.map { $0.deletingLastPathComponent() })
    for p in parents { tree.reloadChildren(of: p) }
    let trashedSet = Set(folders.map { $0.standardizedFileURL })
    let curStd = nav.currentURL.standardizedFileURL
    if trashedSet.contains(curStd) {
        nav.navigate(to: curStd.deletingLastPathComponent())
    } else if let containing = folders.first(where: { nav.currentURL.path.hasPrefix($0.path + "/") }) {
        nav.navigate(to: containing.deletingLastPathComponent())
    } else {
        nav.reload()
    }
    if let err = firstErr {
        showTreeAlert("휴지통 이동 실패", err.localizedDescription)
    }
}

@MainActor
func trashTreeFolder(_ folder: URL, nav: NavigationState, tree: FolderTreeStore) {
    let alert = NSAlert()
    alert.messageText = "\(folder.lastPathComponent) 폴더를 휴지통으로 보내시겠습니까?"
    alert.informativeText = "폴더와 그 안의 모든 내용이 휴지통으로 이동됩니다."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "휴지통으로")
    alert.addButton(withTitle: "취소")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
        try FileSystemService.shared.moveToTrash(folder)
        UndoService.shared.register(.trash(originals: [folder]), label: "휴지통으로 이동")
        let parent = folder.deletingLastPathComponent()
        tree.reloadChildren(of: parent)
        if folder.standardizedFileURL == nav.currentURL.standardizedFileURL {
            nav.navigate(to: parent)
        } else if nav.currentURL.path.hasPrefix(folder.path + "/") {
            nav.navigate(to: parent)
        } else {
            nav.reload()
        }
    } catch {
        showTreeAlert("휴지통 이동 실패", error.localizedDescription)
    }
}

@MainActor
func showTreeAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "확인")
    alert.runModal()
}

// MARK: - "새로 만들기" (shared between sidebar, file table, and file list)

/// Returns a non-colliding child URL by appending " (2)", " (3)", … if needed,
/// preserving the extension.
@MainActor
func uniqueChildURL(_ name: String, in dir: URL) -> URL {
    let fm = FileManager.default
    var candidate = dir.appendingPathComponent(name)
    guard fm.fileExists(atPath: candidate.path) else { return candidate }
    let probe = URL(fileURLWithPath: name)
    let base = probe.deletingPathExtension().lastPathComponent
    let ext = probe.pathExtension
    var i = 2
    repeat {
        let newName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
        candidate = dir.appendingPathComponent(newName)
        i += 1
    } while fm.fileExists(atPath: candidate.path)
    return candidate
}

/// Standard menu items the "새로 만들기" submenu offers everywhere. Each entry
/// is (label, filename) — `nil` filename means "create a folder named 새 폴더".
let newItemTemplates: [(label: String, filename: String?)] = [
    ("폴더",            nil),
    ("텍스트 문서",      "새 텍스트 문서.txt"),
    ("Markdown 문서",    "새 문서.md"),
    ("리치 텍스트 문서",  "새 문서.rtf"),
    ("Shell 스크립트",   "새 스크립트.sh"),
    ("HTML 문서",        "새 문서.html"),
    ("JSON 파일",        "새 데이터.json"),
]

@MainActor
func createNewFolderShared(in dst: URL, nav: NavigationState, tree: FolderTreeStore) {
    let url = uniqueChildURL("새 폴더", in: dst)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        afterCreating(url, parent: dst, nav: nav, tree: tree)
    } catch {
        showTreeAlert("폴더 만들기 실패", error.localizedDescription)
    }
}

@MainActor
func createNewFileShared(name: String, in dst: URL, nav: NavigationState, tree: FolderTreeStore) {
    let url = uniqueChildURL(name, in: dst)
    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
        showTreeAlert("파일 만들기 실패", "\(url.path) 에 파일을 만들 수 없습니다.")
        return
    }
    afterCreating(url, parent: dst, nav: nav, tree: tree)
}

@MainActor
private func afterCreating(_ url: URL, parent: URL, nav: NavigationState, tree: FolderTreeStore) {
    UndoService.shared.register(.create(urls: [url]), label: "새로 만들기")
    tree.reloadChildren(of: parent)
    if parent.standardizedFileURL == nav.currentURL.standardizedFileURL {
        nav.reload(thenSelect: [url])
    }
}

@MainActor
func pasteIntoFolderShared(_ dst: URL, nav: NavigationState, tree: FolderTreeStore) {
    ClipboardService.shared.paste(into: dst) { result in
        switch result {
        case .success(let created):
            tree.reloadChildren(of: dst)
            if dst.standardizedFileURL == nav.currentURL.standardizedFileURL {
                nav.reload(thenSelect: Set(created))
            }
        case .failure(let error):
            showTreeAlert("붙여넣기 실패", error.localizedDescription)
        }
    }
}
