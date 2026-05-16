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

    var body: some View {
        SidebarOutlineRepresentable(nav: nav, tree: tree)
            .background(Color.white)
            .onReceive(NotificationCenter.default.publisher(for: .mfinderRenameSelected)) { _ in
                guard AppFocus.area == .sidebar else { return }
                guard nav.renamingURL == nil else { return }
                nav.renamingURL = nav.currentURL
            }
            .onReceive(NotificationCenter.default.publisher(for: .mfinderTrashSelected)) { _ in
                guard AppFocus.area == .sidebar else { return }
                trashTreeFolder(nav.currentURL, nav: nav, tree: tree)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mfinderTreeCopy)) { _ in
                guard AppFocus.area == .sidebar else { return }
                ClipboardService.shared.copy([nav.currentURL])
            }
            .onReceive(NotificationCenter.default.publisher(for: .mfinderTreeCut)) { _ in
                guard AppFocus.area == .sidebar else { return }
                ClipboardService.shared.cut([nav.currentURL])
            }
            .onReceive(NotificationCenter.default.publisher(for: .mfinderTreePaste)) { _ in
                guard AppFocus.area == .sidebar else { return }
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
        tree.reloadChildren(of: folder.deletingLastPathComponent())
        if folder.standardizedFileURL == nav.currentURL.standardizedFileURL {
            nav.navigate(to: dst)
        }
    } catch {
        showTreeAlert("이름 바꾸기 실패", error.localizedDescription)
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

@MainActor
func pasteIntoFolderShared(_ dst: URL, nav: NavigationState, tree: FolderTreeStore) {
    do {
        let created = try ClipboardService.shared.paste(into: dst)
        tree.reloadChildren(of: dst)
        if dst.standardizedFileURL == nav.currentURL.standardizedFileURL {
            nav.reload(thenSelect: Set(created))
        }
    } catch {
        showTreeAlert("붙여넣기 실패", error.localizedDescription)
    }
}
