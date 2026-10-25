import AppKit
import QuickLookThumbnailing

/// Async content thumbnails (image / PDF / video / document previews) backed by
/// QLThumbnailGenerator, with an in-memory cache. Views ask for a thumbnail and
/// get a callback when one is ready; until then they show the file-type icon.
///
/// Deliberately conservative: never requests a thumbnail for a directory or for
/// an online-only (not-yet-downloaded) cloud file — generating one would force
/// the provider to download the bytes, which is exactly what the online-only
/// badge warns against.
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let generator = QLThumbnailGenerator.shared
    private let cache = NSCache<NSString, NSImage>()
    /// URLs with a request in flight, so repeated cell configs don't pile up
    /// duplicate generations.
    private var inFlight = Set<String>()

    private init() {
        cache.countLimit = 2000
    }

    /// Whether a content thumbnail is appropriate for this item at all.
    static func wantsThumbnail(_ item: FileItem) -> Bool {
        !item.isDirectory && item.cloudState != .notDownloaded
    }

    /// Cache key folds in the file's mtime so an edited file re-thumbnails.
    private func key(_ url: URL, _ px: Int) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return "\(url.path)|\(px)|\(Int(mtime))"
    }

    /// Return a cached thumbnail immediately if present, else nil.
    func cached(for url: URL, pixelSize: Int) -> NSImage? {
        cache.object(forKey: key(url, pixelSize) as NSString)
    }

    /// Request a thumbnail. `completion` runs on the main queue with the image,
    /// or is never called if generation fails (caller keeps its fallback icon).
    func thumbnail(for url: URL, pointSize: CGFloat, completion: @escaping (NSImage) -> Void) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let px = Int((pointSize * scale).rounded())
        let k = key(url, px)
        if let hit = cache.object(forKey: k as NSString) {
            completion(hit); return
        }
        guard !inFlight.contains(k) else { return }
        inFlight.insert(k)

        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: CGFloat(px), height: CGFloat(px)),
            scale: 1,
            representationTypes: .thumbnail
        )
        generator.generateBestRepresentation(for: req) { [weak self] rep, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(k)
                guard let rep else { return }
                let img = rep.nsImage
                self.cache.setObject(img, forKey: k as NSString)
                completion(img)
            }
        }
    }
}
