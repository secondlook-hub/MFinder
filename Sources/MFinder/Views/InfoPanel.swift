import AppKit
import Foundation

/// Finder-style "정보 가져오기" (Get Info) window. A utility panel with an
/// icon + name header and a 일반 정보 grid (종류 / 크기 / 위치 / 만든·수정 날짜 /
/// 버전). Every ⌘I and 속성 entry point routes here so the info view looks the
/// same everywhere — closer to Finder's Get Info than the old text alert.
@MainActor
final class InfoWindowController: NSWindowController, NSWindowDelegate {

    /// One window per item (keyed by standardized path); re-opening focuses the
    /// existing window instead of stacking duplicates.
    private static var openWindows: [String: InfoWindowController] = [:]

    private let targetURL: URL
    private weak var sizeValueField: NSTextField?

    /// Opens (or re-focuses) the Get Info window for `url`.
    static func show(for url: URL) {
        let std = url.standardizedFileURL
        let key = std.path
        if let existing = openWindows[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = InfoWindowController(url: std)
        openWindows[key] = controller
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL) {
        self.targetURL = url
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = Lf("%@ 정보", "\(name)")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        super.init(window: panel)
        panel.delegate = self
        buildContent(name: name)
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        InfoWindowController.openWindows[targetURL.path] = nil
    }

    // MARK: - Content

    private func buildContent(name: String) {
        guard let panel = window else { return }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .localizedTypeDescriptionKey,
            .creationDateKey, .contentModificationDateKey, .fileSizeKey
        ]
        let vals = try? targetURL.resourceValues(forKeys: keys)
        let isDir = vals?.isDirectory ?? false
        let isPkg = vals?.isPackage ?? false
        let typeDesc = vals?.localizedTypeDescription ?? (isDir ? L("폴더") : "")

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd  a hh:mm"
        df.locale = Locale(identifier: "ko_KR")
        let createdStr = vals?.creationDate.map { df.string(from: $0) } ?? "-"
        let modStr = vals?.contentModificationDate.map { df.string(from: $0) } ?? "-"

        // Location: parent folder, with the home directory abbreviated to ~.
        let locationStr = (targetURL.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath

        // Header: large icon + name + type subline.
        let iconView = NSImageView()
        iconView.image = NSWorkspace.shared.icon(forFile: targetURL.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let nameField = NSTextField(labelWithString: name)
        nameField.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        nameField.isSelectable = true
        nameField.lineBreakMode = .byTruncatingMiddle

        let typeField = NSTextField(labelWithString: typeDesc)
        typeField.font = NSFont.systemFont(ofSize: 11)
        typeField.textColor = .secondaryLabelColor

        let headerText = NSStackView(views: [nameField, typeField])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2

        let header = NSStackView(views: [iconView, headerText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let sectionTitle = NSTextField(labelWithString: L("일반 정보:"))
        sectionTitle.font = NSFont.systemFont(ofSize: 11, weight: .bold)

        // Info grid.
        func keyField(_ s: String) -> NSTextField {
            let tf = NSTextField(labelWithString: L(s))
            tf.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            tf.textColor = .secondaryLabelColor
            return tf
        }
        func valueField(_ s: String) -> NSTextField {
            let tf = NSTextField(labelWithString: s)
            tf.font = NSFont.systemFont(ofSize: 12)
            tf.isSelectable = true
            tf.lineBreakMode = .byTruncatingMiddle
            return tf
        }

        var rows: [[NSView]] = []
        rows.append([keyField("종류:"), valueField(typeDesc)])

        // Size — computed off the main thread (folders can be expensive).
        let sizeValue = valueField(L("계산 중…"))
        self.sizeValueField = sizeValue
        rows.append([keyField("크기:"), sizeValue])

        rows.append([keyField("위치:"), valueField(locationStr)])
        rows.append([keyField("만든 날짜:"), valueField(createdStr)])
        rows.append([keyField("수정한 날짜:"), valueField(modStr)])

        // Version — apps / bundles that carry a short version string.
        if isPkg,
           let info = Bundle(url: targetURL)?.infoDictionary,
           let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty {
            rows.append([keyField("버전:"), valueField(version)])
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        // "Finder에서 보기" convenience button.
        let revealButton = NSButton(title: L("Finder에서 보기"), target: self,
                                    action: #selector(revealInFinder))
        revealButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [NSView(), revealButton])
        buttonRow.orientation = .horizontal

        let root = NSStackView(views: [header, separator, sectionTitle, grid, buttonRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.minSize = NSSize(width: 300, height: 220)

        computeSize(isDir: isDir, fileSize: vals?.fileSize)
    }

    private func computeSize(isDir: Bool, fileSize: Int?) {
        if !isDir {
            let bytes = Int64(fileSize ?? 0)
            sizeValueField?.stringValue = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return
        }
        let url = targetURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bytes = InfoWindowController.totalSize(at: url)
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let itemStr = Lf("항목 수: %@", "\(count)")
            DispatchQueue.main.async {
                self?.sizeValueField?.stringValue = "\(sizeStr)  (\(itemStr))"
            }
        }
    }

    @objc private func revealInFinder() {
        FileSystemService.shared.revealInFinder(targetURL)
    }

    nonisolated private static func totalSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [], errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in en {
            guard let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  vals.isRegularFile == true, let size = vals.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
