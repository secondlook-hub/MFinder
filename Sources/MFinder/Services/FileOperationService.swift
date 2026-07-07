import Foundation
import AppKit

/// One planned copy/move. Conflict resolution (overwrite prompts, unique
/// naming) happens BEFORE ops reach this service — dst is final.
struct FileOperation {
    let src: URL
    let dst: URL
    let isMove: Bool
}

/// Runs copy/move batches on a background queue with an Explorer-style
/// progress panel (item name, byte-accurate bar, cancel). Same-volume moves
/// are instant renames; cross-volume moves fall back to copy + delete.
///
/// The panel only appears when the batch is still running after 0.4s, so
/// small operations stay silent. Completion always fires on the main thread
/// with the ops that landed (in order) and the first error, if any.
/// Cancelling deletes the half-written current file and stops — completed
/// items stay.
@MainActor
final class FileOperationService {
    static let shared = FileOperationService()

    private init() {}

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return flag
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            flag = true
        }
    }

    private struct CancelledError: Error {}

    /// `completion` is always invoked on the main thread.
    func perform(_ ops: [FileOperation], title: String,
                 completion: @escaping ([FileOperation], Error?) -> Void) {
        guard !ops.isEmpty else { completion([], nil); return }

        let cancel = CancelFlag()
        let panel = FileProgressPanel(title: title) { cancel.cancel() }
        var finished = false
        // Delay the panel so quick batches never flash a window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !finished { panel.show() }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let totalBytes = ops.reduce(Int64(0)) { $0 + Self.sizeOnDisk($1.src, cancel: cancel) }
            var copiedBytes: Int64 = 0
            var done: [FileOperation] = []
            var firstError: Error?

            for (idx, op) in ops.enumerated() {
                if cancel.isCancelled { break }
                DispatchQueue.main.async {
                    panel.update(itemName: op.src.lastPathComponent,
                                 itemIndex: idx + 1, itemCount: ops.count)
                }
                do {
                    try Self.execute(op, cancel: cancel, totalBytes: totalBytes,
                                     copiedBytes: &copiedBytes) { fraction in
                        DispatchQueue.main.async { panel.setFraction(fraction) }
                    }
                    done.append(op)
                } catch is CancelledError {
                    break
                } catch {
                    if firstError == nil { firstError = error }
                }
            }

            let result = done
            let err = firstError
            DispatchQueue.main.async {
                finished = true
                panel.close()
                completion(result, err)
            }
        }
    }

    // MARK: - Engine (runs on the background queue)

    private nonisolated static func execute(_ op: FileOperation, cancel: CancelFlag,
                                            totalBytes: Int64, copiedBytes: inout Int64,
                                            progress: (Double) -> Void) throws {
        let fm = FileManager.default
        if op.isMove {
            // Fast path: same-volume rename. Cross-volume (or any failure that
            // isn't "destination exists") falls back to copy + delete source.
            do {
                try fm.moveItem(at: op.src, to: op.dst)
                copiedBytes += sizeOnDisk(op.src, cancel: nil, fallbackDst: op.dst)
                if totalBytes > 0 { progress(Double(copiedBytes) / Double(totalBytes)) }
                return
            } catch {
                try copyRecursively(op.src, to: op.dst, cancel: cancel,
                                    totalBytes: totalBytes, copiedBytes: &copiedBytes,
                                    progress: progress)
                try? fm.removeItem(at: op.src)
            }
        } else {
            try copyRecursively(op.src, to: op.dst, cancel: cancel,
                                totalBytes: totalBytes, copiedBytes: &copiedBytes,
                                progress: progress)
        }
    }

    private nonisolated static func copyRecursively(_ src: URL, to dst: URL, cancel: CancelFlag,
                                                    totalBytes: Int64, copiedBytes: inout Int64,
                                                    progress: (Double) -> Void) throws {
        if cancel.isCancelled { throw CancelledError() }
        let fm = FileManager.default
        let values = try src.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

        if values.isSymbolicLink == true {
            let target = try fm.destinationOfSymbolicLink(atPath: src.path)
            try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: target)
            return
        }
        if values.isDirectory == true {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for child in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil,
                                                      options: [])) ?? [] {
                try copyRecursively(child, to: dst.appendingPathComponent(child.lastPathComponent),
                                    cancel: cancel, totalBytes: totalBytes,
                                    copiedBytes: &copiedBytes, progress: progress)
            }
            copyAttributes(from: src, to: dst)
            return
        }

        try streamCopyFile(src, to: dst, cancel: cancel,
                           totalBytes: totalBytes, copiedBytes: &copiedBytes, progress: progress)
    }

    /// Chunked file copy so the progress bar moves within a single large file
    /// and cancellation takes effect mid-file (partial output is deleted).
    private nonisolated static func streamCopyFile(_ src: URL, to dst: URL, cancel: CancelFlag,
                                                   totalBytes: Int64, copiedBytes: inout Int64,
                                                   progress: (Double) -> Void) throws {
        let fm = FileManager.default
        guard let input = InputStream(url: src) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: src.path])
        }
        fm.createFile(atPath: dst.path, contents: nil)
        guard let output = OutputStream(url: dst, append: false) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: dst.path])
        }
        input.open(); output.open()
        defer { input.close(); output.close() }

        let bufferSize = 4 << 20  // 4 MB
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while input.hasBytesAvailable {
            if cancel.isCancelled {
                output.close()
                try? fm.removeItem(at: dst)
                throw CancelledError()
            }
            let read = input.read(&buffer, maxLength: bufferSize)
            if read < 0 {
                try? fm.removeItem(at: dst)
                throw input.streamError ?? CocoaError(.fileReadUnknown)
            }
            if read == 0 { break }
            var written = 0
            while written < read {
                // NOT `&buffer[written]` — inout-to-pointer on a single
                // element passes a temporary, and OutputStream then writes
                // garbage / EFAULTs. Offset from the real base address.
                let n = buffer.withUnsafeBufferPointer { ptr in
                    output.write(ptr.baseAddress! + written, maxLength: read - written)
                }
                if n <= 0 {
                    try? fm.removeItem(at: dst)
                    throw output.streamError ?? CocoaError(.fileWriteUnknown)
                }
                written += n
            }
            copiedBytes += Int64(read)
            if totalBytes > 0 { progress(Double(copiedBytes) / Double(totalBytes)) }
        }
        copyAttributes(from: src, to: dst)
    }

    private nonisolated static func copyAttributes(from src: URL, to dst: URL) {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: src.path) {
            let keep: [FileAttributeKey] = [.modificationDate, .creationDate, .posixPermissions]
            let subset = attrs.filter { keep.contains($0.key) }
            try? fm.setAttributes(subset, ofItemAtPath: dst.path)
        }
    }

    /// Total byte size of a file or directory tree. Used for the progress
    /// denominator — best-effort, 0 on failure (bar stays indeterminate-ish).
    private nonisolated static func sizeOnDisk(_ url: URL, cancel: CancelFlag?,
                                               fallbackDst: URL? = nil) -> Int64 {
        let fm = FileManager.default
        // For post-move accounting the source is gone — measure the destination.
        let target = fm.fileExists(atPath: url.path) ? url : (fallbackDst ?? url)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: target, includingPropertiesForKeys: [.fileSizeKey],
                                  options: [], errorHandler: nil) {
            for case let child as URL in en {
                if let cancel, cancel.isCancelled { break }
                total += (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            }
        }
        return total
    }
}

// MARK: - Progress panel

/// Explorer-style floating progress window: title, current item, N/M counter,
/// byte-fraction bar, cancel button.
@MainActor
private final class FileProgressPanel: NSObject {
    private let panel: NSPanel
    private let itemLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let onCancel: () -> Void

    init(title: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                        styleMask: [.titled, .utilityWindow],
                        backing: .buffered, defer: true)
        super.init()
        panel.title = title
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)

        itemLabel.font = .systemFont(ofSize: 11)
        itemLabel.textColor = .secondaryLabelColor
        itemLabel.lineBreakMode = .byTruncatingMiddle
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0

        let cancelButton = NSButton(title: "취소", target: nil, action: nil)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))

        let infoRow = NSStackView(views: [itemLabel, NSView(), countLabel])
        infoRow.orientation = .horizontal
        infoRow.distribution = .fill

        let stack = NSStackView(views: [titleLabel, bar, infoRow, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        bar.widthAnchor.constraint(equalToConstant: 388).isActive = true
        infoRow.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        stack.setCustomSpacing(10, after: infoRow)

        panel.contentView = stack
        panel.center()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        onCancel()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func update(itemName: String, itemIndex: Int, itemCount: Int) {
        itemLabel.stringValue = itemName
        countLabel.stringValue = "\(itemIndex) / \(itemCount)"
    }

    func setFraction(_ fraction: Double) {
        bar.doubleValue = min(max(fraction, 0), 1)
    }

    func close() {
        panel.orderOut(nil)
    }
}
