import Foundation
import AppKit
import SwiftUI

/// A single item in the clipboard stack. Each entry remembers whether it was
/// added via cut (move) or copy (duplicate), so a stack can hold a mix and
/// each item gets the right action on paste.
struct ClipboardEntry: Hashable, Identifiable {
    let url: URL
    let isCut: Bool
    var id: URL { url }
}

/// Clipboard with stacking semantics: ⌘C / ⌘X accumulate into a stack instead
/// of replacing. A single ⌘V drains the stack, performing copy or move per
/// entry as appropriate. Same URL re-added flips its mode (most recent wins).
///
/// The system pasteboard is the single source of truth — the published `stack`
/// is a cache that's refreshed whenever this process becomes active. This
/// means two MFinder instances share one unified stack: copying multi-files
/// in instance A makes them paste-able (still as a stack with cut/copy flags)
/// in instance B, and draining via paste in either instance empties both.
final class ClipboardService: ObservableObject, @unchecked Sendable {
    static let shared = ClipboardService()

    /// Custom pasteboard type carrying the full ordered stack (URL + isCut
    /// per entry) as JSON. Sits alongside the standard `.fileURL` items so
    /// external apps (Finder, etc.) still see the file URLs.
    private static let stackType = NSPasteboard.PasteboardType("com.secondlook.MFinder.clipboard-stack")

    @Published private(set) var stack: [ClipboardEntry] = []

    private var lastSyncedChangeCount: Int = -1
    private var becomeActiveToken: NSObjectProtocol?

    private init() {
        becomeActiveToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFromPasteboardIfChanged()
        }
        refreshFromPasteboardIfChanged()
    }

    deinit {
        if let token = becomeActiveToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Derived

    var hasContent: Bool { !stack.isEmpty }

    /// Convenience: URLs currently in the stack, preserving insertion order.
    var pending: [URL] { stack.map(\.url) }

    /// O(n) check for "is this URL pending as a cut/move target?". Used by
    /// the file list to render cut items dimmed.
    func isCut(_ url: URL) -> Bool {
        let std = url.standardizedFileURL
        return stack.contains { $0.isCut && $0.url == std }
    }

    /// Convenience for the status bar icon — returns the dominant mode.
    /// Nil if the stack is empty or mixed.
    var dominantMode: Bool? {
        guard !stack.isEmpty else { return nil }
        if stack.allSatisfy(\.isCut) { return true }
        if stack.allSatisfy({ !$0.isCut }) { return false }
        return nil
    }

    // MARK: - Stack mutation

    func copy(_ urls: [URL]) {
        add(urls, asCut: false)
    }

    func cut(_ urls: [URL]) {
        add(urls, asCut: true)
    }

    private func add(_ urls: [URL], asCut: Bool) {
        guard !urls.isEmpty else { return }
        refreshFromPasteboardIfChanged()
        var next = stack
        let incoming = Set(urls.map { $0.standardizedFileURL })
        next.removeAll { incoming.contains($0.url.standardizedFileURL) }
        for url in urls {
            next.append(ClipboardEntry(url: url.standardizedFileURL, isCut: asCut))
        }
        commit(next)
    }

    func remove(_ url: URL) {
        refreshFromPasteboardIfChanged()
        let std = url.standardizedFileURL
        var next = stack
        next.removeAll { $0.url.standardizedFileURL == std }
        commit(next)
    }

    func clear() {
        commit([])
    }

    // MARK: - Paste

    /// Drains the stack into `destination`. Each entry is moved (cut) or
    /// copied based on its `isCut` flag. Conflict prompts run up front on the
    /// main thread; the actual copy/move then runs in the background via
    /// FileOperationService (progress panel + cancel for big batches).
    /// `completion` receives the URLs created at the destination and fires on
    /// the main thread. The whole paste registers as one ⌘Z entry.
    ///
    /// A same-named item at the destination prompts 덮어쓰기/건너뛰기/취소.
    /// With several conflicts the dialog offers "남은 항목 모두에 적용" so one
    /// answer can cover the rest. 취소 keeps the not-yet-pasted entries in the
    /// stack (they're still pending); otherwise the stack is cleared in both
    /// this process and the system pasteboard so users don't double-paste.
    @MainActor
    func paste(into destination: URL, completion: @escaping (Result<[URL], Error>) -> Void) {
        refreshFromPasteboardIfChanged()
        let entries = stack
        guard !entries.isEmpty else {
            completion(.failure(NSError(domain: "MFinder.Clipboard", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "클립보드가 비어 있습니다."])))
            return
        }

        let fm = FileManager.default
        // Count conflicts up front so each dialog can say how many are left
        // and offer a blanket answer for them.
        var conflictsLeft = entries.filter { entry in
            let target = destination.appendingPathComponent(entry.url.lastPathComponent)
            return target.standardizedFileURL != entry.url.standardizedFileURL
                && fm.fileExists(atPath: target.path)
        }.count

        var blanket: FileConflictChoice?
        var cancelledAtIndex: Int?
        var ops: [FileOperation] = []

        for (idx, entry) in entries.enumerated() {
            let target = destination.appendingPathComponent(entry.url.lastPathComponent)
            let sameLocation = target.standardizedFileURL == entry.url.standardizedFileURL
            if entry.isCut {
                // Cut + paste into the same folder is a no-op.
                if sameLocation { continue }
                if fm.fileExists(atPath: target.path) {
                    conflictsLeft -= 1
                    let choice = blanket ?? askFileConflict(name: entry.url.lastPathComponent,
                                                            remainingConflicts: conflictsLeft,
                                                            blanket: &blanket)
                    if choice == .skip { continue }
                    if choice == .cancel { cancelledAtIndex = idx; break }
                    try? fm.removeItem(at: target)
                }
                ops.append(FileOperation(src: entry.url, dst: target, isMove: true))
            } else if sameLocation {
                // Copy + paste into the same folder → make a duplicate, never
                // overwrite the source onto itself.
                ops.append(FileOperation(src: entry.url,
                                         dst: uniqueDestination(for: entry.url, in: destination),
                                         isMove: false))
            } else {
                if fm.fileExists(atPath: target.path) {
                    conflictsLeft -= 1
                    let choice = blanket ?? askFileConflict(name: entry.url.lastPathComponent,
                                                            remainingConflicts: conflictsLeft,
                                                            blanket: &blanket)
                    if choice == .skip { continue }
                    if choice == .cancel { cancelledAtIndex = idx; break }
                    try? fm.removeItem(at: target)
                }
                ops.append(FileOperation(src: entry.url, dst: target, isMove: false))
            }
        }

        if let stopIdx = cancelledAtIndex {
            // Keep the entry the user cancelled on plus everything after it.
            commit(Array(entries[stopIdx...]))
        } else {
            commit([])
        }

        guard !ops.isEmpty else { completion(.success([])); return }
        let title = ops.allSatisfy(\.isMove) ? "이동 중…"
                  : ops.allSatisfy({ !$0.isMove }) ? "복사 중…" : "붙여넣는 중…"
        FileOperationService.shared.perform(ops, title: title) { done, err in
            let moved = done.filter(\.isMove).map { (from: $0.src, to: $0.dst) }
            let copied = done.filter { !$0.isMove }.map(\.dst)
            var actions: [UndoAction] = []
            if !moved.isEmpty { actions.append(.move(pairs: moved)) }
            if !copied.isEmpty { actions.append(.create(urls: copied)) }
            if let single = actions.first, actions.count == 1 {
                UndoService.shared.register(single, label: "붙여넣기")
            } else if !actions.isEmpty {
                UndoService.shared.register(.batch(actions), label: "붙여넣기")
            }
            if done.isEmpty, let err {
                completion(.failure(err))
            } else {
                completion(.success(done.map(\.dst)))
            }
        }
    }

    // 덮어쓰기 확인 UI lives in FileConflictPrompt.swift (shared with drag-and-drop).

    // MARK: - Pasteboard ↔ stack sync

    private func commit(_ entries: [ClipboardEntry]) {
        writePasteboard(entries)
        lastSyncedChangeCount = NSPasteboard.general.changeCount
        stack = entries
    }

    /// Re-read the system pasteboard if another process (or app) modified it.
    /// Cheap to call — early-returns when the pasteboard hasn't changed.
    private func refreshFromPasteboardIfChanged() {
        let cc = NSPasteboard.general.changeCount
        if cc == lastSyncedChangeCount { return }
        lastSyncedChangeCount = cc
        let entries = readStackFromPasteboard()
        if entries != stack { stack = entries }
    }

    private func writePasteboard(_ entries: [ClipboardEntry]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !entries.isEmpty else { return }

        let metaData = try? JSONEncoder().encode(entries.map(EntryPayload.init))
        var items: [NSPasteboardItem] = []
        for (idx, entry) in entries.enumerated() {
            let item = NSPasteboardItem()
            item.setString(entry.url.absoluteString, forType: .fileURL)
            // Carry the full stack metadata on the first item so a single
            // `pb.data(forType: stackType)` reads it back without iterating.
            if idx == 0, let data = metaData {
                item.setData(data, forType: Self.stackType)
            }
            items.append(item)
        }
        pb.writeObjects(items)
    }

    private func readStackFromPasteboard() -> [ClipboardEntry] {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.stackType),
           let payload = try? JSONDecoder().decode([EntryPayload].self, from: data) {
            let entries = payload.compactMap { $0.toEntry() }
            if !entries.isEmpty { return entries }
        }
        // Fallback: some other app (or older MFinder) put plain file URLs on
        // the pasteboard. Treat them as copy entries.
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            return urls.map { ClipboardEntry(url: $0.standardizedFileURL, isCut: false) }
        }
        return []
    }

    private struct EntryPayload: Codable {
        let url: String
        let isCut: Bool
        init(_ entry: ClipboardEntry) {
            self.url = entry.url.absoluteString
            self.isCut = entry.isCut
        }
        func toEntry() -> ClipboardEntry? {
            guard let u = URL(string: url) else { return nil }
            return ClipboardEntry(url: u.standardizedFileURL, isCut: isCut)
        }
    }

    // MARK: - Helpers

    private func uniqueDestination(for src: URL, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(src.lastPathComponent)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let baseName = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        var i = 2
        repeat {
            let newName = ext.isEmpty
                ? "\(baseName) (\(i))"
                : "\(baseName) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            i += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
