import AppKit
import Foundation

/// Explorer-style batch rename for a multi-selection. Two modes in one
/// dialog, applied in this precedence:
///   1. 새 이름 filled → every item becomes "새 이름 (n)", numbering follows
///      the given start (extension preserved), like Windows Explorer's F2 on
///      a multi-selection.
///   2. 찾기 filled → substring replace inside each filename.
/// Collisions fall back to " (2)"-style unique names. The whole batch
/// registers as a single ⌘Z entry.
@MainActor
func promptBatchRename(_ urls: [URL], nav: NavigationState) {
    guard urls.count > 1 else { return }

    let alert = NSAlert()
    alert.messageText = "일괄 이름 바꾸기 (\(urls.count)개 항목)"
    alert.informativeText = "새 이름을 입력하면 \"새 이름 (1)\", \"새 이름 (2)\"… 순서로 바뀝니다.\n비워 두고 찾기/바꾸기를 입력하면 각 이름에서 해당 문자열만 바뀝니다."
    alert.addButton(withTitle: "적용")
    alert.addButton(withTitle: "취소")

    func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }
    let newNameField = NSTextField(string: "")
    newNameField.placeholderString = "예: 휴가 사진"
    let startField = NSTextField(string: "1")
    let findField = NSTextField(string: "")
    let replaceField = NSTextField(string: "")

    let grid = NSGridView(views: [
        [makeLabel("새 이름:"), newNameField, makeLabel("시작 번호:"), startField],
        [makeLabel("찾기:"), findField, makeLabel("바꾸기:"), replaceField],
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 6
    newNameField.widthAnchor.constraint(equalToConstant: 150).isActive = true
    findField.widthAnchor.constraint(equalToConstant: 150).isActive = true
    startField.widthAnchor.constraint(equalToConstant: 60).isActive = true
    replaceField.widthAnchor.constraint(equalToConstant: 60).isActive = true
    grid.layoutSubtreeIfNeeded()
    grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
    alert.accessoryView = grid
    alert.window.initialFirstResponder = newNameField

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let newBase = newNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let find = findField.stringValue
    let fm = FileManager.default
    var pairs: [(from: URL, to: URL)] = []

    if !newBase.isEmpty {
        var n = Int(startField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        for url in urls {
            let ext = url.pathExtension
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = (ext.isEmpty || isDir) ? "\(newBase) (\(n))" : "\(newBase) (\(n)).\(ext)"
            n += 1
            let parent = url.deletingLastPathComponent()
            var dst = parent.appendingPathComponent(name)
            if dst.standardizedFileURL == url.standardizedFileURL { continue }
            if fm.fileExists(atPath: dst.path) { dst = uniqueChildURL(name, in: parent) }
            pairs.append((from: url, to: dst))
        }
    } else if !find.isEmpty {
        for url in urls {
            let newName = url.lastPathComponent.replacingOccurrences(of: find,
                                                                     with: replaceField.stringValue)
            guard !newName.isEmpty, newName != url.lastPathComponent else { continue }
            let parent = url.deletingLastPathComponent()
            var dst = parent.appendingPathComponent(newName)
            if fm.fileExists(atPath: dst.path) { dst = uniqueChildURL(newName, in: parent) }
            pairs.append((from: url, to: dst))
        }
    } else {
        return
    }

    guard !pairs.isEmpty else { return }
    var done: [(from: URL, to: URL)] = []
    var firstErr: Error?
    for (src, dst) in pairs {
        do {
            try fm.moveItem(at: src, to: dst)
            done.append((from: src, to: dst))
        } catch {
            if firstErr == nil { firstErr = error }
        }
    }
    UndoService.shared.register(.move(pairs: done), label: "일괄 이름 바꾸기")
    nav.reload(thenSelect: Set(done.map(\.to)))
    if let err = firstErr {
        showTreeAlert("일부 항목의 이름을 바꾸지 못했습니다", err.localizedDescription)
    }
}
