import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Finder-style Quick Actions: lightweight, in-place transforms on files.
/// Currently image rotation (re-encoded to the original format) and
/// "create PDF" from a set of images. Returns created/changed URLs so the
/// caller can register undo and refresh.
enum QuickActionsService {

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "tiff", "tif", "heic", "heif", "bmp", "webp"
    ]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    enum QAError: LocalizedError {
        case notAnImage, decodeFailed, encodeFailed, noImages
        var errorDescription: String? {
            switch self {
            case .notAnImage:    return L("이미지 파일이 아닙니다.")
            case .decodeFailed:  return L("이미지를 읽을 수 없습니다.")
            case .encodeFailed:  return L("이미지를 저장할 수 없습니다.")
            case .noImages:      return L("이미지를 선택하세요.")
            }
        }
    }

    /// Rotate an image file 90° in place, re-encoding to its original type.
    static func rotate(_ url: URL, clockwise: Bool) throws {
        guard isImage(url) else { throw QAError.notAnImage }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw QAError.decodeFailed
        }
        let type = CGImageSourceGetType(src) ?? (UTType.png.identifier as CFString)
        let w = cg.width, h = cg.height
        let outW = h, outH = w  // swapped for 90°
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw QAError.encodeFailed
        }
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        ctx.draw(cg, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        guard let rotated = ctx.makeImage() else { throw QAError.encodeFailed }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw QAError.encodeFailed
        }
        CGImageDestinationAddImage(dest, rotated, nil)
        guard CGImageDestinationFinalize(dest) else { throw QAError.encodeFailed }
        try data.write(to: url, options: .atomic)
    }

    /// Combine image files into a single PDF next to the first one.
    /// Returns the new PDF's URL.
    @discardableResult
    static func createPDF(from urls: [URL], named baseName: String) throws -> URL {
        let images = urls.filter(isImage)
        guard !images.isEmpty else { throw QAError.noImages }
        let doc = PDFDocument()
        var idx = 0
        for url in images {
            guard let img = NSImage(contentsOf: url), let page = PDFPage(image: img) else { continue }
            doc.insert(page, at: idx)
            idx += 1
        }
        guard idx > 0 else { throw QAError.decodeFailed }
        let dir = images[0].deletingLastPathComponent()
        var out = dir.appendingPathComponent(baseName).appendingPathExtension("pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = dir.appendingPathComponent("\(baseName) (\(n))").appendingPathExtension("pdf")
            n += 1
        }
        guard doc.write(to: out) else { throw QAError.encodeFailed }
        return out
    }
}
