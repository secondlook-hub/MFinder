import AppKit

/// Receiving files dragged from apps that vend **promises** instead of real
/// file URLs — Outlook / Mail attachments, Photos, some browsers, and
/// remote-desktop clients. The promised bytes don't exist on disk yet; the
/// provider only writes them once we ask it to, so a plain `public.file-url`
/// read sees nothing and the drop silently does nothing. We resolve the
/// promise into a staging directory first, then feed the real files through
/// the normal import pipeline.
enum DragImport {
    /// Pasteboard types to register (alongside `.fileURL`) so AppKit routes
    /// promise drags to our drop handlers.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// File-promise receivers present on a dragging pasteboard, if any.
    static func receivers(from pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver]) ?? []
    }

    /// Resolve the promises into a throwaway staging directory, then call
    /// `completion` on the main actor with the real file URLs plus the staging
    /// directory (so the caller can delete it once the files are imported).
    static func receive(_ receivers: [NSFilePromiseReceiver],
                        completion: @escaping @MainActor ([URL], URL) -> Void) {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MFinderDrop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let queue = OperationQueue()
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for r in receivers {
            group.enter()
            r.receivePromisedFiles(atDestination: staging, options: [:],
                                   operationQueue: queue) { url, err in
                if err == nil { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(urls, staging) }
        }
    }
}

/// Shared drop/import pipeline used by every drop target: conflict prompts →
/// background copy/move (progress panel) → undo registration → optional
/// staging cleanup. `completion` fires on the main actor with what landed so
/// each caller can run its own refresh / error alert.
///
/// Self-drops and drops back into an item's own folder are handled the Finder
/// way: a move into the same folder is a no-op, a copy duplicates under a
/// " (2)" name. Promised files live in a staging dir, so for them this always
/// resolves to a plain copy with conflict checks.
@MainActor
func importDroppedFiles(_ sources: [URL], into dst: URL, move: Bool,
                        cleanup: URL? = nil,
                        completion: @escaping (_ landed: [URL], _ error: Error?) -> Void) {
    let fm = FileManager.default
    let stdDst = dst.standardizedFileURL

    var conflictsLeft = sources.filter { src in
        let stdSrc = src.standardizedFileURL
        guard stdSrc != stdDst else { return false }
        if move, stdSrc.deletingLastPathComponent() == stdDst { return false }
        let plainTarget = dst.appendingPathComponent(src.lastPathComponent)
        return plainTarget.standardizedFileURL != stdSrc
            && fm.fileExists(atPath: plainTarget.path)
    }.count

    var blanket: FileConflictChoice?
    var ops: [FileOperation] = []
    for src in sources {
        let stdSrc = src.standardizedFileURL
        if stdSrc == stdDst { continue }
        let plainTarget = dst.appendingPathComponent(src.lastPathComponent)
        let sameParent = stdSrc.deletingLastPathComponent() == stdDst
        let target: URL
        if sameParent || plainTarget.standardizedFileURL == stdSrc {
            // Into its own folder: a move is a no-op; a copy duplicates.
            if move { continue }
            target = uniqueImportName(src.lastPathComponent, in: dst)
        } else {
            if fm.fileExists(atPath: plainTarget.path) {
                conflictsLeft -= 1
                let choice = blanket ?? askFileConflict(name: src.lastPathComponent,
                                                        remainingConflicts: conflictsLeft,
                                                        blanket: &blanket)
                if choice == .skip { continue }
                if choice == .cancel { break }
                if choice == .keepBoth {
                    ops.append(FileOperation(src: src,
                                             dst: uniqueImportName(src.lastPathComponent, in: dst),
                                             isMove: move))
                    continue
                }
                try? fm.removeItem(at: plainTarget)
            }
            target = plainTarget
        }
        ops.append(FileOperation(src: src, dst: target, isMove: move))
    }

    guard !ops.isEmpty else {
        if let cleanup { try? fm.removeItem(at: cleanup) }
        completion([], nil)
        return
    }

    FileOperationService.shared.perform(ops, title: move ? "이동 중…" : "복사 중…") { done, err in
        let landed = done.map(\.dst)
        if move {
            UndoService.shared.register(.move(pairs: done.map { (from: $0.src, to: $0.dst) }),
                                        label: "이동")
        } else {
            UndoService.shared.register(.create(urls: landed), label: "복사")
        }
        if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
        completion(landed, err)
    }
}

/// " (2)", " (3)", … suffix to avoid colliding with an existing item.
private func uniqueImportName(_ name: String, in dir: URL) -> URL {
    let fm = FileManager.default
    var candidate = dir.appendingPathComponent(name)
    guard fm.fileExists(atPath: candidate.path) else { return candidate }
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var i = 2
    repeat {
        let newName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
        candidate = dir.appendingPathComponent(newName)
        i += 1
    } while fm.fileExists(atPath: candidate.path)
    return candidate
}
