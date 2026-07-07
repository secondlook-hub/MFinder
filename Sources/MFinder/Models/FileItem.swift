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

    var displayName: String { name }

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
