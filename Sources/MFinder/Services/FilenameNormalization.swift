import Foundation

/// Unicode normalization for filenames.
///
/// Korean names arrive on disk in two incompatible encodings of the same text:
/// NFC (precomposed 한, 3 bytes) and NFD (decomposed ᄒ+ᅡ+ᆫ, 9 bytes). APFS
/// stores whichever it is handed and treats the two as the same name, but the
/// bytes travel badly — Git sees NFD paths as different files, Windows and
/// Linux render broken jamo, and archives carry the decomposed form onward.
/// On this machine every 카카오톡/텔레그램/Finder-created name is NFD.
///
/// Two behaviours of the platform make this subtle, both verified rather than
/// assumed:
///
/// 1. **Swift `String ==` compares by canonical equivalence.** An NFD string
///    equals its NFC form, so `name != name.precomposed…` is *always false*.
///    Detecting the difference requires comparing UTF-8 bytes. The same is
///    true of `URL ==`, `URL.path ==`, and `Set<URL>` membership — those are
///    already normalization-proof and need no special handling.
///
/// 2. **Every `FileManager` write API decomposes.** `createDirectory(at:)`,
///    `createDirectory(atPath:)`, and `moveItem` all store NFD no matter what
///    they are handed — Foundation normalizes at the path boundary. Only raw
///    POSIX calls on explicit UTF-8 bytes preserve NFC. That is why `apply`
///    goes through `rename(2)` instead of `FileManager.moveItem`.
enum FilenameNormalization {

    /// True when the name is stored decomposed and would change if normalized.
    ///
    /// Compares UTF-8 bytes on purpose: `==` on Swift strings is canonical
    /// equivalence and would report every name as already normalized.
    static func needsNormalization(_ name: String) -> Bool {
        Array(name.utf8) != Array(name.precomposedStringWithCanonicalMapping.utf8)
    }

    // MARK: Volume capability

    /// `f_fstypename` of the volume holding `url` — "apfs", "hfs", "exfat",
    /// "smbfs"… Empty when it can't be determined.
    static func filesystemType(of url: URL) -> String {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return "" }
        return withUnsafeBytes(of: &fs.f_fstypename) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// HFS+ normalizes every name to NFD in the filesystem itself, so a
    /// converted name is undone the moment it is written. Detecting this lets
    /// the UI explain the refusal instead of silently doing nothing.
    static func isFutile(at url: URL) -> Bool {
        filesystemType(of: url).hasPrefix("hfs")
    }

    // MARK: Planning

    /// Rename pairs needed to bring `urls` (and optionally their descendants)
    /// to NFC. Already-NFC items are omitted, so an empty result means there
    /// is nothing to do.
    ///
    /// Deepest paths come first: renaming a parent first would invalidate
    /// every child path collected underneath it.
    ///
    /// Names are read with the `atPath` (String) APIs, which return the bytes
    /// as stored. The URL-based enumerators are avoided here — round-tripping
    /// a name through `URL` decomposes it, which would hide every NFD name
    /// this function exists to find.
    static func plan(for urls: [URL], recursive: Bool) -> [(from: String, to: String)] {
        let fm = FileManager.default
        var paths: [String] = []

        for url in urls {
            // `url.path` is already decomposed by URL, so the selected item's
            // own name has to be recovered from its parent's directory listing
            // — otherwise an item stored as NFC looks like it needs converting.
            // The `==` here is canonical equivalence, which is exactly the
            // match we want: find the entry that *is* this name, whatever form
            // it is stored in.
            let parentPath = url.deletingLastPathComponent().path
            let wanted = url.lastPathComponent
            let trueName = (try? fm.contentsOfDirectory(atPath: parentPath))?
                .first { $0 == wanted } ?? wanted
            let path = parentPath + "/" + trueName
            paths.append(path)
            guard recursive else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let e = fm.enumerator(atPath: path) else { continue }
            while let rel = e.nextObject() as? String {
                paths.append(path + "/" + rel)
            }
        }

        paths.sort { $0.utf8.filter { $0 == UInt8(ascii: "/") }.count
                   > $1.utf8.filter { $0 == UInt8(ascii: "/") }.count }

        return paths.compactMap { path in
            guard let slash = path.lastIndex(of: "/") else { return nil }
            let dir = String(path[path.startIndex..<slash])
            let name = String(path[path.index(after: slash)...])
            guard needsNormalization(name) else { return nil }
            return (from: path, to: dir + "/" + name.precomposedStringWithCanonicalMapping)
        }
    }

    // MARK: Applying

    /// Performs the renames via `rename(2)`. Returns what actually succeeded so
    /// the caller registers exactly that much with UndoService.
    ///
    /// `FileManager.moveItem` cannot be used: it re-decomposes the destination
    /// name, turning every rename here into a no-op.
    static func apply(_ pairs: [(from: String, to: String)])
        -> (done: [(from: String, to: String)], firstError: String?) {
        var done: [(from: String, to: String)] = []
        var firstError: String?
        for (from, to) in pairs {
            let ok = from.withCString { f in to.withCString { t in rename(f, t) } } == 0
            if ok {
                done.append((from: from, to: to))
            } else if firstError == nil {
                firstError = String(cString: strerror(errno))
            }
        }
        return (done, firstError)
    }
}
