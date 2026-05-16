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
final class ClipboardService: ObservableObject, @unchecked Sendable {
    static let shared = ClipboardService()

    @Published private(set) var stack: [ClipboardEntry] = []

    /// Bumped whenever the app comes to the foreground. Serves as a SwiftUI
    /// dependency hook for `hasContent` so that views update when another
    /// MFinder process (or any other app) puts URLs onto the system
    /// pasteboard — without this, a freshly launched second instance's
    /// "붙여넣기" button stays disabled because its own `stack` is empty.
    @Published private(set) var pasteboardSnapshot: Int = 0

    private var becomeActiveToken: NSObjectProtocol?

    private init() {
        becomeActiveToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pasteboardSnapshot &+= 1
        }
    }

    deinit {
        if let token = becomeActiveToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// True if there's something to paste — either our local stack has items
    /// or the system pasteboard carries file URLs (from another instance or
    /// any external app). Reading the pasteboard here lets cross-instance
    /// copy/paste work: instance A copies, instance B reads what A wrote.
    var hasContent: Bool {
        if !stack.isEmpty { return true }
        return systemPasteboardHasFileURLs
    }

    private var systemPasteboardHasFileURLs: Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]
        return !(urls?.isEmpty ?? true)
    }

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
        let allCut  = stack.allSatisfy(\.isCut)
        let allCopy = stack.allSatisfy { !$0.isCut }
        if allCut  { return true }
        if allCopy { return false }
        return nil  // mixed
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
        // Replace existing entries that match the incoming URLs, then append.
        // Order is preserved for existing-not-rewritten items; new/updated
        // items go to the end so the most recent action is most "fresh".
        let incoming = Set(urls.map { $0.standardizedFileURL })
        stack.removeAll { incoming.contains($0.url.standardizedFileURL) }
        for url in urls {
            stack.append(ClipboardEntry(url: url.standardizedFileURL, isCut: asCut))
        }
        writePasteboard(urls)
    }

    func remove(_ url: URL) {
        let std = url.standardizedFileURL
        stack.removeAll { $0.url.standardizedFileURL == std }
    }

    func clear() {
        stack = []
    }

    // MARK: - Paste

    /// Drains the stack into `destination`. Each entry is moved (cut) or
    /// copied based on its `isCut` flag. Returns the URLs that were
    /// successfully created at the destination. Always clears the stack
    /// after attempting all items (so users don't end up double-pasting).
    @discardableResult
    func paste(into destination: URL) throws -> [URL] {
        // If the stack is empty, fall back to the system pasteboard as plain copy.
        let entries: [ClipboardEntry]
        if !stack.isEmpty {
            entries = stack
        } else {
            let pbURLs = readPasteboardURLs()
            entries = pbURLs.map { ClipboardEntry(url: $0, isCut: false) }
        }
        guard !entries.isEmpty else {
            throw NSError(domain: "MFinder.Clipboard", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "클립보드가 비어 있습니다."])
        }

        let fm = FileManager.default
        var created: [URL] = []
        var firstError: Error?
        for entry in entries {
            let dst = uniqueDestination(for: entry.url, in: destination)
            do {
                if entry.isCut {
                    try fm.moveItem(at: entry.url, to: dst)
                } else {
                    try fm.copyItem(at: entry.url, to: dst)
                }
                created.append(dst)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        // Drain the stack whether or not every item succeeded — partial
        // success is still progress and we don't want the user to accidentally
        // re-paste the surviving entries with another ⌘V.
        stack = []
        if created.isEmpty, let err = firstError { throw err }
        return created
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

    private func writePasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    private func readPasteboardURLs() -> [URL] {
        let pb = NSPasteboard.general
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }
}
