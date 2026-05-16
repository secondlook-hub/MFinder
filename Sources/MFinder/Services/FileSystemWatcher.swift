import Foundation

/// Per-folder file-system change watcher backed by kqueue
/// (`DispatchSource.makeFileSystemObjectSource`). One vnode source per
/// watched directory, each holding an `O_EVTONLY` file descriptor.
///
/// Compared to FSEvents this is:
///  - Reliable on every macOS version including 26 (FSEvents has had quiet
///    periods after the initial event burst in our testing on this OS).
///  - Non-recursive by definition — events fire only for direct changes in
///    the watched folder, which is exactly what we need.
///  - Cheap (one fd per watched path; we watch at most ~20 folders).
final class FileSystemWatcher: @unchecked Sendable {
    private let onChange: (Set<URL>) -> Void
    private let lock = NSLock()
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var descriptors: [String: Int32] = [:]
    private let callbackQueue = DispatchQueue.global(qos: .userInitiated)

    init(latency: CFTimeInterval = 0.3, onChange: @escaping (Set<URL>) -> Void) {
        // `latency` accepted for API compatibility with the previous FSEvents
        // implementation; vnode-source events are already coalesced by the
        // kernel within a runloop tick.
        _ = latency
        self.onChange = onChange
    }

    deinit {
        clearAll()
    }

    func setWatch(_ urls: [URL]) {
        let normalized = urls.map { $0.standardizedFileURL.path }
        let desired = Set(normalized)

        lock.lock()
        let current = Set(sources.keys)
        let toAdd = desired.subtracting(current)
        let toRemove = current.subtracting(desired)
        lock.unlock()

        for path in toRemove { stopWatching(path: path) }
        for path in toAdd    { startWatching(path: path) }
    }

    func stop() {
        clearAll()
    }

    // MARK: - per-path setup / teardown

    private func startWatching(path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("MFinder.FSWatch: open() failed for %@: errno=%d",
                  path as NSString, errno)
            return
        }

        // Trigger on contents change (write), inode delete, rename, attribute change.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: callbackQueue
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                self.onChange([url])
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        lock.lock()
        sources[path] = source
        descriptors[path] = fd
        lock.unlock()
    }

    private func stopWatching(path: String) {
        lock.lock()
        let src = sources.removeValue(forKey: path)
        descriptors.removeValue(forKey: path)
        lock.unlock()
        src?.cancel()    // cancel handler closes the fd
    }

    private func clearAll() {
        lock.lock()
        let allSources = sources
        sources.removeAll()
        descriptors.removeAll()
        lock.unlock()
        for (_, s) in allSources { s.cancel() }
    }
}
