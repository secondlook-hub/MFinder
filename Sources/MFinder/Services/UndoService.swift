import Foundation
import AppKit

/// One undoable file operation batch. Inverses are computed structurally:
/// moves reverse, copies/creations delete what they made, trash restores from
/// ~/.Trash by name (best-effort — Finder may have renamed on collision, in
/// which case that item is skipped).
indirect enum UndoAction {
    /// Items relocated (paste-cut, drag-move, rename). Undo moves each
    /// `to` back to `from`.
    case move(pairs: [(from: URL, to: URL)])
    /// Items materialized at new URLs (paste-copy, drag-copy, 새로 만들기,
    /// 바로 가기 만들기). Undo trashes them (recoverable by hand).
    case create(urls: [URL])
    /// Items sent to the Trash. Undo moves ~/.Trash/<name> back to where it
    /// came from.
    case trash(originals: [URL])
    /// Renames recorded as raw path bytes rather than URLs (이름 NFC로 정규화).
    /// `URL` normalizes any path it is handed to NFD, which would erase the
    /// very distinction this action exists to restore, and `FileManager.moveItem`
    /// re-decomposes on write — so both directions go through `rename(2)` on
    /// the exact stored bytes.
    case renameBytes(pairs: [(from: String, to: String)])
    /// Mixed operation (e.g. a paste that both moved cut entries and copied
    /// copy entries) undone as one ⌘Z.
    case batch([UndoAction])
}

/// App-wide undo/redo stacks for file operations (⌘Z / ⇧⌘Z). Views register
/// batches after a successful operation; undo performs the inverse on disk and
/// lets each pane's FSEvent watcher refresh the UI.
@MainActor
final class UndoService: ObservableObject {
    static let shared = UndoService()

    struct Entry {
        let action: UndoAction
        let label: String
    }

    @Published private(set) var undoStack: [Entry] = []
    @Published private(set) var redoStack: [Entry] = []

    private let maxDepth = 50

    private init() {}

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoMenuTitle: String { undoStack.last.map { "\($0.label) 실행 취소" } ?? "실행 취소" }
    var redoMenuTitle: String { redoStack.last.map { "\($0.label) 다시 실행" } ?? "다시 실행" }

    func register(_ action: UndoAction, label: String) {
        guard !isEmpty(action) else { return }
        undoStack.append(Entry(action: action, label: label))
        if undoStack.count > maxDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let entry = undoStack.popLast() else { NSSound.beep(); return }
        var firstErr: Error?
        if let inverse = perform(inverseOf: entry.action, firstError: &firstErr) {
            redoStack.append(Entry(action: inverse, label: entry.label))
        } else {
            reportFailure("실행 취소 실패", error: firstErr)
        }
    }

    func redo() {
        guard let entry = redoStack.popLast() else { NSSound.beep(); return }
        var firstErr: Error?
        if let inverse = perform(inverseOf: entry.action, firstError: &firstErr) {
            undoStack.append(Entry(action: inverse, label: entry.label))
        } else {
            reportFailure("다시 실행 실패", error: firstErr)
        }
    }

    private func isEmpty(_ action: UndoAction) -> Bool {
        switch action {
        case .move(let pairs):      return pairs.isEmpty
        case .create(let urls):     return urls.isEmpty
        case .trash(let originals): return originals.isEmpty
        case .renameBytes(let pairs): return pairs.isEmpty
        case .batch(let actions):   return actions.allSatisfy { isEmpty($0) }
        }
    }

    /// Executes the inverse of `action` on disk. Returns the action that
    /// re-does it (the inverse of the inverse), or nil when nothing could be
    /// reverted (everything already gone / moved away / errored).
    private func perform(inverseOf action: UndoAction, firstError: inout Error?) -> UndoAction? {
        let fm = FileManager.default
        switch action {
        case .move(let pairs):
            var reverted: [(from: URL, to: URL)] = []
            for (from, to) in pairs.reversed() {
                guard fm.fileExists(atPath: to.path),
                      !fm.fileExists(atPath: from.path) else { continue }
                do {
                    try fm.moveItem(at: to, to: from)
                    reverted.append((from: to, to: from))
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            return reverted.isEmpty ? nil : .move(pairs: reverted)

        case .renameBytes(let pairs):
            var reverted: [(from: String, to: String)] = []
            for (from, to) in pairs.reversed() {
                let ok = to.withCString { t in from.withCString { f in rename(t, f) } } == 0
                if ok {
                    reverted.append((from: to, to: from))
                } else if firstError == nil {
                    firstError = NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                                         userInfo: [NSLocalizedDescriptionKey:
                                                        String(cString: strerror(errno))])
                }
            }
            return reverted.isEmpty ? nil : .renameBytes(pairs: reverted)

        case .create(let urls):
            var trashed: [URL] = []
            for url in urls where fm.fileExists(atPath: url.path) {
                do {
                    // Deleting a copy is destructive — route through the Trash
                    // so even an undo can be recovered by hand.
                    try FileSystemService.shared.moveToTrash(url)
                    trashed.append(url)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            // Redoing a "create" can't re-copy (source unknown) — restore from Trash.
            return trashed.isEmpty ? nil : .trash(originals: trashed)

        case .trash(let originals):
            let trashDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            var restored: [(from: URL, to: URL)] = []
            for original in originals.reversed() {
                let inTrash = trashDir.appendingPathComponent(original.lastPathComponent)
                guard fm.fileExists(atPath: inTrash.path),
                      !fm.fileExists(atPath: original.path) else { continue }
                do {
                    try fm.moveItem(at: inTrash, to: original)
                    restored.append((from: inTrash, to: original))
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            return restored.isEmpty ? nil : .move(pairs: restored)

        case .batch(let actions):
            var inverses: [UndoAction] = []
            for sub in actions.reversed() {
                if let inv = perform(inverseOf: sub, firstError: &firstError) {
                    inverses.append(inv)
                }
            }
            return inverses.isEmpty ? nil : .batch(inverses)
        }
    }

    private func reportFailure(_ title: String, error: Error?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error?.localizedDescription
            ?? "되돌릴 항목을 찾을 수 없습니다. 이미 이동되었거나 삭제되었을 수 있습니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
