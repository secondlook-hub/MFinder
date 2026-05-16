import Foundation
import AppKit

enum ArchiveFormat: String, CaseIterable {
    case zip      = "zip"
    case sevenZ   = "7z"
    case tarGz    = "tar.gz"
    case tarBz2   = "tar.bz2"
    case tarXz    = "tar.xz"
    case tar      = "tar"

    var displayName: String {
        switch self {
        case .zip:    return "Zip (.zip)"
        case .sevenZ: return "7-Zip (.7z)"
        case .tarGz:  return "Tar+GZip (.tar.gz)"
        case .tarBz2: return "Tar+BZip2 (.tar.bz2)"
        case .tarXz:  return "Tar+XZ (.tar.xz)"
        case .tar:    return "Tar (.tar)"
        }
    }
}

final class ArchiveService {
    static let shared = ArchiveService()

    // Detected at first use.
    private lazy var tools: [String: String] = detectTools()
    /// Cached lookup for Bandizip.app — used as a graceful fallback when the
    /// CLI archive tools (unrar / unar / 7z) aren't installed but Bandizip
    /// is present. Bandizip is GUI-only on macOS, so we hand the archive
    /// off via NSWorkspace and let the user click Extract there.
    lazy var bandizipAppURL: URL? = {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.bandisoft.mac.bandizip") {
            return url
        }
        let fallback = "/Applications/Bandizip.app"
        return FileManager.default.fileExists(atPath: fallback) ? URL(fileURLWithPath: fallback) : nil
    }()

    private func detectTools() -> [String: String] {
        let candidates: [(String, [String])] = [
            ("zip",   ["/usr/bin/zip"]),
            ("unzip", ["/usr/bin/unzip"]),
            ("tar",   ["/usr/bin/tar"]),
            ("gzip",  ["/usr/bin/gzip"]),
            ("bzip2", ["/usr/bin/bzip2"]),
            ("xz",    ["/usr/bin/xz", "/opt/homebrew/bin/xz", "/usr/local/bin/xz"]),
            ("7z",    ["/opt/homebrew/bin/7z", "/usr/local/bin/7z", "/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"]),
            ("unar",  ["/opt/homebrew/bin/unar", "/usr/local/bin/unar"]),
            ("unrar", ["/opt/homebrew/bin/unrar", "/usr/local/bin/unrar"])
        ]
        var result: [String: String] = [:]
        for (key, paths) in candidates {
            for p in paths where FileManager.default.isExecutableFile(atPath: p) {
                result[key] = p
                break
            }
        }
        return result
    }

    func has(_ tool: String) -> Bool { tools[tool] != nil }
    func path(_ tool: String) -> String? { tools[tool] }

    /// Hands the archive off to Bandizip.app for the user to extract there.
    /// Throws if Bandizip.app isn't installed.
    func openWithBandizip(_ urls: [URL]) throws {
        guard let app = bandizipAppURL else {
            throw makeError("Bandizip.app이 설치되어 있지 않습니다.")
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config, completionHandler: nil)
    }

    // MARK: - Archive detection

    private let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2",
        "xz", "txz", "jar", "war", "ear"
    ]

    func isArchive(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".tar.gz") || n.hasSuffix(".tar.bz2") || n.hasSuffix(".tar.xz") {
            return true
        }
        return archiveExtensions.contains(url.pathExtension.lowercased())
    }

    /// Strip all archive extensions: "foo.tar.gz" → "foo".
    func basename(ofArchive url: URL) -> String {
        var name = url.lastPathComponent
        let lower = name.lowercased()
        let composite = [".tar.gz", ".tar.bz2", ".tar.xz"]
        for c in composite where lower.hasSuffix(c) {
            return String(name.dropLast(c.count))
        }
        if let dot = name.lastIndex(of: ".") {
            name = String(name[..<dot])
        }
        return name
    }

    // MARK: - Compress

    /// Returns whether this format is currently usable on this machine.
    func canCompress(to format: ArchiveFormat) -> Bool {
        switch format {
        case .zip:    return has("zip")
        case .sevenZ: return has("7z")
        case .tarGz:  return has("tar") && has("gzip")
        case .tarBz2: return has("tar") && has("bzip2")
        case .tarXz:  return has("tar") && has("xz")
        case .tar:    return has("tar")
        }
    }

    /// Compresses the given items (inside cwd) into a single archive named `archiveName`.
    /// `archiveName` should already include the extension.
    func compress(_ urls: [URL], into directory: URL, archiveName: String, format: ArchiveFormat) throws {
        guard !urls.isEmpty else { return }
        let dst = directory.appendingPathComponent(archiveName)
        let task = Process()
        task.currentDirectoryURL = directory

        switch format {
        case .zip:
            guard let bin = path("zip") else { throw makeError("zip 명령을 찾을 수 없습니다.") }
            task.executableURL = URL(fileURLWithPath: bin)
            var args = ["-r", "-q", dst.path]
            args.append(contentsOf: urls.map { $0.lastPathComponent })
            task.arguments = args

        case .sevenZ:
            guard let bin = path("7z") else { throw makeError("7z 명령을 찾을 수 없습니다. Homebrew로 'p7zip'을 설치하세요.") }
            task.executableURL = URL(fileURLWithPath: bin)
            var args = ["a", "-bd", dst.path]
            args.append(contentsOf: urls.map { $0.lastPathComponent })
            task.arguments = args

        case .tar:
            guard let bin = path("tar") else { throw makeError("tar 명령을 찾을 수 없습니다.") }
            task.executableURL = URL(fileURLWithPath: bin)
            var args = ["-cf", dst.path]
            args.append(contentsOf: urls.map { $0.lastPathComponent })
            task.arguments = args

        case .tarGz:
            guard let bin = path("tar") else { throw makeError("tar 명령을 찾을 수 없습니다.") }
            task.executableURL = URL(fileURLWithPath: bin)
            var args = ["-czf", dst.path]
            args.append(contentsOf: urls.map { $0.lastPathComponent })
            task.arguments = args

        case .tarBz2:
            guard let bin = path("tar") else { throw makeError("tar 명령을 찾을 수 없습니다.") }
            task.executableURL = URL(fileURLWithPath: bin)
            var args = ["-cjf", dst.path]
            args.append(contentsOf: urls.map { $0.lastPathComponent })
            task.arguments = args

        case .tarXz:
            guard let bin = path("tar") else { throw makeError("tar 명령을 찾을 수 없습니다.") }
            task.executableURL = URL(fileURLWithPath: bin)
            var args = ["-cJf", dst.path]
            args.append(contentsOf: urls.map { $0.lastPathComponent })
            task.arguments = args
        }

        try runAndWait(task)
    }

    // MARK: - Extract

    func canExtract(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let n = url.lastPathComponent.lowercased()
        let bandizipFallback = bandizipAppURL != nil
        if ext == "zip" || ext == "jar" || ext == "war" || ext == "ear" { return has("unzip") || has("unar") || bandizipFallback }
        if ext == "tar" { return has("tar") }
        if n.hasSuffix(".tar.gz") || ext == "tgz" || ext == "gz" { return has("tar") }
        if n.hasSuffix(".tar.bz2") || ext == "tbz" || ext == "tbz2" || ext == "bz2" { return has("tar") }
        if n.hasSuffix(".tar.xz") || ext == "txz" || ext == "xz" { return has("tar") && has("xz") }
        if ext == "7z" { return has("7z") || has("unar") || bandizipFallback }
        if ext == "rar" { return has("unrar") || has("unar") || bandizipFallback }
        return has("unar") || bandizipFallback  // last resort
    }

    /// Extracts archive into its own directory next to the archive (folder named after archive basename).
    @discardableResult
    func extractIntoFolder(_ archive: URL) throws -> URL {
        let parent = archive.deletingLastPathComponent()
        let baseName = basename(ofArchive: archive)
        var dst = parent.appendingPathComponent(baseName)
        var i = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = parent.appendingPathComponent("\(baseName) (\(i))")
            i += 1
        }
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: false)
        try extract(archive, into: dst)
        return dst
    }

    /// Extracts directly into archive's parent directory ("Extract Here").
    func extractHere(_ archive: URL) throws {
        let parent = archive.deletingLastPathComponent()
        try extract(archive, into: parent)
    }

    func extract(_ archive: URL, into directory: URL) throws {
        let ext = archive.pathExtension.lowercased()
        let n = archive.lastPathComponent.lowercased()
        let task = Process()
        task.currentDirectoryURL = directory

        if ext == "zip" || ext == "jar" || ext == "war" || ext == "ear" {
            guard let bin = path("unzip") ?? path("unar") else { throw makeError("unzip 도구가 없습니다.") }
            task.executableURL = URL(fileURLWithPath: bin)
            if bin.hasSuffix("unar") {
                task.arguments = ["-q", "-o", directory.path, archive.path]
            } else {
                task.arguments = ["-q", archive.path, "-d", directory.path]
            }
        } else if ext == "tar" {
            guard let bin = path("tar") else { throw makeError("tar 명령이 없습니다.") }
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["-xf", archive.path, "-C", directory.path]
        } else if n.hasSuffix(".tar.gz") || ext == "tgz" || ext == "gz" {
            guard let bin = path("tar") else { throw makeError("tar 명령이 없습니다.") }
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["-xzf", archive.path, "-C", directory.path]
        } else if n.hasSuffix(".tar.bz2") || ext == "tbz" || ext == "tbz2" || ext == "bz2" {
            guard let bin = path("tar") else { throw makeError("tar 명령이 없습니다.") }
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["-xjf", archive.path, "-C", directory.path]
        } else if n.hasSuffix(".tar.xz") || ext == "txz" || ext == "xz" {
            guard let bin = path("tar") else { throw makeError("tar 명령이 없습니다.") }
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["-xJf", archive.path, "-C", directory.path]
        } else if ext == "7z" {
            if let bin = path("7z") ?? path("unar") {
                task.executableURL = URL(fileURLWithPath: bin)
                if bin.hasSuffix("unar") {
                    task.arguments = ["-q", "-o", directory.path, archive.path]
                } else {
                    task.arguments = ["x", "-bd", "-y", "-o\(directory.path)", archive.path]
                }
            } else if bandizipAppURL != nil {
                try openWithBandizip([archive])
                return
            } else {
                throw makeError("7z 압축을 풀려면 'brew install p7zip' 또는 'brew install unar', 또는 Bandizip.app이 필요합니다.")
            }
        } else if ext == "rar" {
            if let bin = path("unrar") ?? path("unar") {
                task.executableURL = URL(fileURLWithPath: bin)
                if bin.hasSuffix("unar") {
                    task.arguments = ["-q", "-o", directory.path, archive.path]
                } else {
                    task.arguments = ["x", "-y", archive.path, directory.path + "/"]
                }
            } else if bandizipAppURL != nil {
                // RAR is proprietary — macOS ships no extractor by default.
                // Hand off to Bandizip when no CLI is installed.
                try openWithBandizip([archive])
                return
            } else {
                throw makeError("RAR 압축을 풀려면 'brew install unar' (또는 unrar), 또는 Bandizip.app이 필요합니다.")
            }
        } else {
            if let bin = path("unar") {
                task.executableURL = URL(fileURLWithPath: bin)
                task.arguments = ["-q", "-o", directory.path, archive.path]
            } else if bandizipAppURL != nil {
                try openWithBandizip([archive])
                return
            } else {
                throw makeError("이 형식은 지원되지 않습니다. 'brew install unar' 또는 Bandizip.app을 설치해 보세요.")
            }
        }

        try runAndWait(task)
    }

    // MARK: - Test / info

    func testArchive(_ archive: URL) throws -> String {
        let ext = archive.pathExtension.lowercased()
        let n = archive.lastPathComponent.lowercased()
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        if ext == "zip", let bin = path("unzip") {
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["-t", archive.path]
        } else if ext == "tar" || n.contains(".tar."), let bin = path("tar") {
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["-tf", archive.path]
        } else if ext == "7z", let bin = path("7z") {
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["t", archive.path]
        } else {
            return "이 형식은 검사할 수 없습니다."
        }
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func archiveInfo(_ archive: URL) throws -> String {
        let ext = archive.pathExtension.lowercased()
        let n = archive.lastPathComponent.lowercased()
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        if ext == "zip", let bin = path("unzip") {
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["-l", archive.path]
        } else if (ext == "tar" || n.contains(".tar.")), let bin = path("tar") {
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["-tvf", archive.path]
        } else if ext == "7z", let bin = path("7z") {
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["l", archive.path]
        } else {
            return "정보를 표시할 수 없습니다."
        }
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Helpers

    private func runAndWait(_ task: Process) throws {
        let pipe = Pipe()
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "알 수 없는 오류"
            throw makeError("명령 실행 실패 (코드 \(task.terminationStatus)): \(msg)")
        }
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(domain: "MFinder.Archive", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
