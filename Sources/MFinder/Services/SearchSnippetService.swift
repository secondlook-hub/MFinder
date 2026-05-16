import Foundation
import AppKit
import PDFKit

/// Reads the matched file off-main-thread, finds the first line containing the
/// search query, and produces a short context-windowed snippet for display in
/// the "내용" column of search results. Results are cached per (path, query) so
/// scrolling doesn't repeatedly re-scan the same file.
final class SearchSnippetService: @unchecked Sendable {
    static let shared = SearchSnippetService()

    /// Number of characters to show on each side of the match.
    private let contextRadius: Int = 60

    // Two-tier cache so repeated multi-word searches reuse extracted text:
    //   textCache  — keyed by file path, value = (mtime + decoded text)
    //   snippetCache — keyed by (path, tokens.cacheKey), value = computed snippet
    private struct TextEntry {
        let mtime: Date
        let text: String
    }
    private var textCache: [String: TextEntry] = [:]
    private var snippetCache: [String: String] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "MFinder.snippet", qos: .userInitiated, attributes: .concurrent
    )

    /// Per-format file-size cap. Bigger files get an empty snippet so the UI
    /// doesn't stall reading huge documents. Plain text uses mmap so we can
    /// allow it large; PDF pulls full text through PDFKit so it's more costly.
    private func maxSize(forExt ext: String) -> Int {
        switch ext {
        case "pdf":
            return 30_000_000        // 30 MB
        case "docx", "xlsx", "pptx":
            return 50_000_000        // 50 MB
        case "rtf", "rtfd", "doc", "odt", "html", "htm":
            return 20_000_000        // 20 MB (NSAttributedString parsing is heavier)
        default:
            return 200_000_000       // 200 MB (mmap-friendly plain text / source)
        }
    }

    /// Async snippet lookup. Completion is invoked on the main queue.
    /// Returns empty string when file can't be scanned or no include token
    /// occurs in its content (filename-only match case).
    func snippet(for url: URL, tokens: SearchTokens, completion: @escaping (String) -> Void) {
        guard !tokens.includes.isEmpty else {
            DispatchQueue.main.async { completion("") }
            return
        }

        let key = snippetKey(for: url, tokens: tokens)
        lock.lock()
        if let cached = snippetCache[key] {
            lock.unlock()
            DispatchQueue.main.async { completion(cached) }
            return
        }
        lock.unlock()

        queue.async { [self] in
            let result = extractSnippet(from: url, tokens: tokens) ?? ""
            lock.lock()
            snippetCache[key] = result
            lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }

    func clearCache() {
        lock.lock()
        textCache.removeAll()
        snippetCache.removeAll()
        lock.unlock()
    }

    // MARK: - Implementation

    private func snippetKey(for url: URL, tokens: SearchTokens) -> String {
        "\(url.standardizedFileURL.path)|\(tokens.cacheKey)"
    }

    private func extractSnippet(from url: URL, tokens: SearchTokens) -> String? {
        let ext = url.pathExtension.lowercased()
        // Per-format size guard.
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           size > maxSize(forExt: ext) {
            return nil
        }

        // PDF gets a specialized page-by-page path so a 500-page document
        // exits as soon as the first matching line is found instead of
        // pulling the entire text through PDFKit.
        if ext == "pdf" {
            return extractPDFSnippet(from: url, tokens: tokens)
        }

        // Generic path: extract full text (via mtime-keyed cache), scan for line.
        guard let text = cachedText(for: url), !text.isEmpty else { return nil }
        return findInText(text, tokens: tokens)
    }

    /// Loads text content for `url`, reusing the result across multiple queries
    /// as long as the file's modification date hasn't changed.
    private func cachedText(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            )?.contentModificationDate ?? .distantPast

        lock.lock()
        if let entry = textCache[path], entry.mtime == mtime {
            lock.unlock()
            return entry.text
        }
        lock.unlock()

        guard let text = readText(from: url) else { return nil }
        lock.lock()
        textCache[path] = TextEntry(mtime: mtime, text: text)
        // Prevent unbounded growth — drop arbitrary entries if cache gets huge.
        if textCache.count > 200 {
            for k in textCache.keys.prefix(50) { textCache.removeValue(forKey: k) }
        }
        lock.unlock()
        return text
    }

    /// Finds the first line that satisfies the include/exclude tokens and
    /// returns a context-windowed snippet around the primary token's match.
    private func findInText(_ text: String, tokens: SearchTokens) -> String? {
        let primary = tokens.primary
        guard !primary.isEmpty else { return nil }
        let primaryLower = primary.lowercased()
        let separators = CharacterSet(charactersIn: "\n\r")
        for raw in text.components(separatedBy: separators) {
            let lower = raw.lowercased()
            // Must contain the primary token (anchor for the snippet).
            guard lower.contains(primaryLower) else { continue }
            // Reject if any exclude appears on this same line.
            if tokens.excludes.contains(where: { lower.contains($0.lowercased()) }) { continue }
            if let range = raw.range(of: primary, options: .caseInsensitive) {
                return buildSnippet(line: raw, matchRange: range)
            }
        }
        return nil
    }

    /// PDF-specific extraction: iterate pages, find the first matching line,
    /// stop reading on success. Avoids loading whole-document text for big PDFs.
    private func extractPDFSnippet(from url: URL, tokens: SearchTokens) -> String? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        let pageCount = pdf.pageCount
        guard pageCount > 0 else { return nil }
        for i in 0..<pageCount {
            autoreleasepool {
                _ = pdf.page(at: i)  // warm
            }
            guard let page = pdf.page(at: i),
                  let pageText = page.string, !pageText.isEmpty else { continue }
            if let snippet = findInText(pageText, tokens: tokens) {
                return snippet
            }
        }
        return nil
    }

    private func buildSnippet(line: String, matchRange: Range<String.Index>) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Short line — just return it as-is.
        if trimmed.count <= contextRadius * 2 + 20 {
            return trimmed
        }
        // Long line — window around the match.
        let matchStart = line.distance(from: line.startIndex, to: matchRange.lowerBound)
        let matchEnd   = line.distance(from: line.startIndex, to: matchRange.upperBound)
        let snippetStart = max(0, matchStart - contextRadius)
        let snippetEnd   = min(line.count, matchEnd + contextRadius)
        let startIdx = line.index(line.startIndex, offsetBy: snippetStart)
        let endIdx   = line.index(line.startIndex, offsetBy: snippetEnd)
        var snippet = String(line[startIdx..<endIdx])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if snippetStart > 0 { snippet = "…" + snippet }
        if snippetEnd < line.count { snippet = snippet + "…" }
        return snippet
    }

    // MARK: - File text decoding

    /// Knownly plain-text extensions. Anything else falls through to optimistic
    /// decoding (which works for code files with unusual extensions) and then to
    /// rich-text/RTF/Word import via NSAttributedString.
    private let plainTextExtensions: Set<String> = [
        // documents
        "txt", "md", "markdown", "rst", "log", "csv", "tsv",
        // data / config
        "json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "env",
        "plist", "strings", "properties", "gitignore", "gitconfig", "dockerfile", "makefile",
        // web
        "html", "htm", "css", "scss", "sass", "less", "svg",
        "js", "mjs", "cjs", "ts", "jsx", "tsx", "vue", "astro",
        // languages
        "swift", "m", "mm", "h", "hpp", "hh", "c", "cc", "cpp", "cxx",
        "py", "rb", "php", "rs", "go", "java", "kt", "kts", "scala", "groovy",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "sql", "graphql", "gql", "proto", "thrift",
        "lua", "pl", "tcl", "r", "jl", "ex", "exs", "erl", "elm", "fsx", "fs",
        "dart", "nim", "cr", "zig", "v", "vb", "vbs", "cs", "asm", "s",
        "tex", "bib", "nix",
    ]

    private func readText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let basename = url.lastPathComponent.lowercased()

        // Direct plain-text path
        if plainTextExtensions.contains(ext) || plainTextExtensions.contains(basename) || ext.isEmpty {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
               let text = decodeText(data) {
                return text
            }
        }

        // PDF via PDFKit — handles all text-based PDFs, image-only PDFs return nil.
        if ext == "pdf" {
            if let pdf = PDFDocument(url: url), let s = pdf.string, !s.isEmpty {
                return s
            }
        }

        // Office Open XML formats: unzip the relevant inner XML files and scrape
        // the text nodes with regex. Avoids needing a full Office parser library.
        switch ext {
        case "docx":
            // word/document.xml: <w:t>text</w:t> nodes hold the body text.
            if let s = unzipMember(archive: url, member: "word/document.xml") {
                return extractXMLText(s, openTag: "<w:t", closeTag: "</w:t>")
            }
        case "xlsx":
            // Shared strings + inline strings. sharedStrings.xml is where most
            // cell text lives; inline strings live inside each sheet XML.
            var collected = ""
            if let s = unzipMember(archive: url, member: "xl/sharedStrings.xml") {
                collected += extractXMLText(s, openTag: "<t", closeTag: "</t>")
            }
            // Also scan each sheet for inline-string cells (<is><t>…</t></is>).
            for i in 1...20 {
                if let s = unzipMember(archive: url, member: "xl/worksheets/sheet\(i).xml") {
                    collected += " " + extractXMLText(s, openTag: "<t", closeTag: "</t>")
                } else { break }
            }
            if !collected.isEmpty { return collected }
        case "pptx":
            // Each slide's text lives in ppt/slides/slideN.xml with <a:t> nodes.
            var collected = ""
            for i in 1...200 {
                guard let s = unzipMember(archive: url, member: "ppt/slides/slide\(i).xml") else { break }
                collected += extractXMLText(s, openTag: "<a:t", closeTag: "</a:t>") + "\n"
            }
            if !collected.isEmpty { return collected }
        default:
            break
        }

        // Rich documents (RTF, legacy Word .doc, ODT, HTML) via NSAttributedString.
        let richExtensions: Set<String> = ["rtf", "rtfd", "doc", "odt", "html", "htm"]
        if richExtensions.contains(ext) {
            if let attr = try? NSAttributedString(
                url: url, options: [:], documentAttributes: nil) {
                return attr.string
            }
        }

        // Optimistic last attempt: try plain-text decoding regardless of extension.
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let text = decodeText(data), looksLikeText(text) {
            return text
        }
        return nil
    }

    /// Runs `unzip -p archive member` and returns the captured stdout as a
    /// UTF-8 string. Returns nil if the member doesn't exist or fails to extract.
    private func unzipMember(archive: URL, member: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", archive.path, member]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Scrapes text content from XML by collecting every substring between
    /// `openTag…>` and `closeTag`. Returns concatenated text with spaces, with
    /// common XML entities decoded.
    private func extractXMLText(_ xml: String, openTag: String, closeTag: String) -> String {
        var result = ""
        var cursor = xml.startIndex
        while cursor < xml.endIndex,
              let openStart = xml.range(of: openTag, range: cursor..<xml.endIndex) {
            // Find the end of the open tag '>' from openStart.lowerBound
            guard let gt = xml.range(of: ">", range: openStart.upperBound..<xml.endIndex) else { break }
            let textStart = gt.upperBound
            guard let closeRange = xml.range(of: closeTag, range: textStart..<xml.endIndex) else { break }
            let textRange = textStart..<closeRange.lowerBound
            result += xml[textRange]
            result += " "
            cursor = closeRange.upperBound
        }
        return result
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private func looksLikeText(_ s: String) -> Bool {
        // Reject if >5% NUL bytes or replacement characters → probably binary.
        var bad = 0
        var total = 0
        for scalar in s.unicodeScalars.prefix(1024) {
            total += 1
            if scalar.value == 0 || scalar == "\u{FFFD}" { bad += 1 }
        }
        return total == 0 || (Double(bad) / Double(total)) < 0.05
    }

    private func decodeText(_ data: Data) -> String? {
        // 1) Hard BOMs first — these are unambiguous.
        if data.count >= 3,
           data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.count >= 2 {
            if data[0] == 0xFF, data[1] == 0xFE {
                return String(data: data, encoding: .utf16LittleEndian)
            }
            if data[0] == 0xFE, data[1] == 0xFF {
                return String(data: data, encoding: .utf16BigEndian)
            }
        }

        // 2) Strict UTF-8: only accept if every byte is valid UTF-8 AND there
        //    are no replacement characters. A CP949-encoded Korean file can
        //    occasionally pass the byte-level UTF-8 parser by coincidence and
        //    show 모자 characters; this guard catches that case.
        if let utf8 = String(data: data, encoding: .utf8), looksLikeWellFormedUTF8(utf8) {
            return utf8
        }

        // 3) Apple's heuristic detector — considers character frequency across
        //    the user's preferred encodings. Hands back the converted string
        //    and the chosen encoding. This is the same logic TextEdit uses.
        var converted: NSString?
        let cp949Raw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue))
        let suggested: [NSNumber] = [
            NSNumber(value: String.Encoding.utf8.rawValue),
            NSNumber(value: cp949Raw),  // EUC-KR / CP949
            NSNumber(value: String.Encoding.shiftJIS.rawValue),
            NSNumber(value: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            NSNumber(value: String.Encoding.windowsCP1252.rawValue),
            NSNumber(value: String.Encoding.isoLatin1.rawValue)
        ]
        let detected = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: suggested,
                .useOnlySuggestedEncodingsKey: false,
                .allowLossyKey: false
            ],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if detected != 0, let s = converted as String? { return s }

        // 4) Last-ditch single-encoding attempts.
        if cp949Raw != kCFStringEncodingInvalidId,
           let s = String(data: data, encoding: String.Encoding(rawValue: cp949Raw)) {
            return s
        }
        if let s = String(data: data, encoding: .shiftJIS) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    /// UTF-8 byte parser may accept a CP949 file by chance; this looks at the
    /// decoded result and rejects it if the proportion of unprintable / replacement
    /// characters or extremely-rare blocks suggests a misdecode.
    private func looksLikeWellFormedUTF8(_ s: String) -> Bool {
        var weird = 0
        var total = 0
        for scalar in s.unicodeScalars.prefix(2048) {
            total += 1
            let v = scalar.value
            // Replacement char (decoder error indicator) or NUL
            if v == 0 || v == 0xFFFD { weird += 1; continue }
            // Control characters except common whitespace
            if v < 0x20, v != 0x09, v != 0x0A, v != 0x0D { weird += 1; continue }
            // Private-use areas are valid Unicode but unusual in real documents
            if (0xE000...0xF8FF).contains(v) { weird += 1 }
        }
        guard total > 0 else { return true }
        return Double(weird) / Double(total) < 0.02
    }
}
