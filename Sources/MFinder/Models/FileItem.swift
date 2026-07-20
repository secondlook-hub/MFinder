import Foundation
import AppKit

struct FileItem: Identifiable, Hashable {
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date
    let creationDate: Date
    let typeDescription: String
    let icon: NSImage
    /// Cloud sync state for File Provider items (OneDrive / Google Drive /
    /// iCloud Drive). `.notCloud` for ordinary local files.
    let cloudState: CloudState

    enum CloudState {
        case notCloud
        /// Online-only: the name and size are known, the bytes are not on disk.
        /// Opening or copying materializes it — macOS downloads transparently,
        /// so this is a display concern, not a capability one.
        case notDownloaded
        case downloaded
    }

    var displayName: String { name }

    var isNotDownloaded: Bool { cloudState == .notDownloaded }

    var ext: String {
        isDirectory ? "" : url.pathExtension.lowercased()
    }

    var sizeString: String {
        if isDirectory { return "" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: size)
    }

    var modificationString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd  a hh:mm"
        f.locale = Locale(identifier: "ko_KR")
        return f.string(from: modificationDate)
    }

    var creationString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd  a hh:mm"
        f.locale = Locale(identifier: "ko_KR")
        return f.string(from: creationDate)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
