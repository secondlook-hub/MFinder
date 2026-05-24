import Foundation
import AppKit
import NetFS

/// Mounts remote file shares (SMB / AFP / WebDAV / FTP / NFS) via the system
/// `NetFS` framework — the same plumbing Finder's ⌘K dialog uses, so the
/// authentication sheet, Keychain integration, and volume naming all match
/// what users already know.
///
/// Recent server URLs are persisted in UserDefaults so the connect dialog and
/// the 네트워크 sidebar section can show them on relaunch.
@MainActor
final class NetworkConnectService: ObservableObject {
    static let shared = NetworkConnectService()

    @Published private(set) var recentServers: [URL] = []

    private let defaults = UserDefaults.standard
    private let recentKey = "MFinder.recentServers"
    private let recentLimit = 16

    private init() {
        loadRecent()
    }

    // MARK: - Recents

    private func loadRecent() {
        let strs = defaults.stringArray(forKey: recentKey) ?? []
        recentServers = strs.compactMap { URL(string: $0) }
    }

    private func saveRecent() {
        defaults.set(recentServers.map(\.absoluteString), forKey: recentKey)
    }

    func addRecent(_ url: URL) {
        let normalized = normalize(url)
        recentServers.removeAll { normalize($0) == normalized }
        recentServers.insert(normalized, at: 0)
        if recentServers.count > recentLimit {
            recentServers = Array(recentServers.prefix(recentLimit))
        }
        saveRecent()
    }

    func removeRecent(_ url: URL) {
        let n = normalize(url)
        recentServers.removeAll { normalize($0) == n }
        saveRecent()
    }

    func clearRecent() {
        recentServers.removeAll()
        saveRecent()
    }

    /// Strip credentials and trailing slashes so two entries that differ only
    /// in those superficial details collapse into one recent row.
    private func normalize(_ url: URL) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.user = nil
        comps?.password = nil
        var s = comps?.url?.absoluteString ?? url.absoluteString
        while s.hasSuffix("/") && s.count > "smb://".count { s.removeLast() }
        return URL(string: s) ?? url
    }

    // MARK: - Mount

    /// Mount `url`. On success, `completion` receives the mounted volume URLs
    /// (typically one, e.g. `/Volumes/share`). On failure, an Error with a
    /// user-readable description. The NetFS framework handles the credentials
    /// sheet and Keychain itself.
    func connect(to url: URL, completion: @escaping (Result<[URL], Error>) -> Void) {
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(
            url as CFURL,
            nil,    // mountpath: nil → default /Volumes/<share>
            nil,    // user: nil → prompt or use stored credentials
            nil,    // password: nil → prompt
            nil,    // open options
            nil,    // mount options
            &requestID,
            DispatchQueue.main
        ) { [weak self] status, _, paths in
            if status == 0 {
                let urls: [URL] = {
                    if let arr = paths as? [String] {
                        return arr.map { URL(fileURLWithPath: $0) }
                    }
                    return []
                }()
                self?.addRecent(url)
                completion(.success(urls))
            } else {
                completion(.failure(Self.error(for: status)))
            }
        }
        if status != 0 {
            // Synchronous failure (bad URL, etc.) — the callback never fires.
            completion(.failure(Self.error(for: status)))
        }
    }

    /// Unmount the volume at `mountPoint`. macOS handles the actual ejection
    /// via DiskArbitration; here we just ask for it politely.
    func disconnect(_ mountPoint: URL, completion: ((Error?) -> Void)? = nil) {
        FileManager.default.unmountVolume(at: mountPoint, options: []) { error in
            DispatchQueue.main.async { completion?(error) }
        }
    }

    // MARK: - Mount discovery

    /// Currently-mounted volumes that NetFS considers non-local — i.e. the
    /// network shares the user mounted via SMB/AFP/etc.
    func mountedRemoteVolumes() -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeIsLocalKey]
        guard let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }
        return vols.filter { v in
            let vals = try? v.resourceValues(forKeys: [.volumeIsLocalKey])
            return vals?.volumeIsLocal == false
        }
    }

    /// If `server` is currently mounted, return its mount point (e.g.
    /// `/Volumes/share`). Matched via the volume's `volumeURLForRemounting`
    /// attribute, which the system populates with the original mount URL.
    func mountPoint(for server: URL) -> URL? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        guard let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return nil
        }
        let target = normalize(server)
        for v in vols {
            if let remount = try? v.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
               normalize(remount) == target {
                return v
            }
        }
        return nil
    }

    // MARK: - Errors

    private static func error(for status: Int32) -> NSError {
        let msg: String
        switch status {
        case -6600:           msg = "사용자 인증에 실패했습니다."
        case -6602:           msg = "암호가 필요합니다."
        case -1073741412:     msg = "지원하지 않는 URL 스킴입니다."
        case -65280...(-1):   msg = "서버에 연결할 수 없습니다. (NetFS \(status))"
        default:              msg = "서버 연결 실패 (코드: \(status))"
        }
        return NSError(
            domain: "MFinder.NetFS", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
    }
}
