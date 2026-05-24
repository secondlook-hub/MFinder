import AppKit

/// Finder-style "서버에 연결" panel.
///
/// Layout: URL field on top, a list of recent servers underneath, and a
/// 취소 / 연결 button pair at the bottom. The recent list is a simple
/// NSTableView; selecting (or double-clicking) a row populates the URL
/// field, and double-click commits the connection.
///
/// Connection itself is delegated to `NetworkConnectService` which wraps
/// `NetFSMountURLAsync` — so the credentials sheet, Keychain integration,
/// and volume naming all come from the system.
@MainActor
final class ServerConnectDialog: NSWindowController {

    static let shared = ServerConnectDialog()

    private var urlField: NSTextField!
    private var recentTable: NSTableView!
    private var connectButton: NSButton!
    private var progressIndicator: NSProgressIndicator!
    private var statusLabel: NSTextField!

    private var onConnected: ((URL) -> Void)?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "서버에 연결"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        super.init(window: panel)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    /// Present as an app-modal panel. `onConnect` fires with the newly
    /// mounted volume URL once mounting completes successfully.
    func present(initialURL: String = "smb://", onConnect: ((URL) -> Void)? = nil) {
        self.onConnected = onConnect
        urlField.stringValue = initialURL
        urlField.currentEditor()?.selectedRange = NSRange(location: initialURL.count, length: 0)
        reloadRecent()
        statusLabel.stringValue = ""
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        connectButton.isEnabled = true
        guard let panel = window else { return }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(urlField)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - View construction

    private func buildContent() {
        guard let panel = window else { return }
        let content = NSView(frame: panel.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        panel.contentView = content

        let intro = NSTextField(labelWithString: "연결할 서버의 주소를 입력하세요. (예: smb://server/share)")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.frame = NSRect(x: 20, y: 320, width: 440, height: 18)
        intro.autoresizingMask = [.width, .minYMargin]
        content.addSubview(intro)

        urlField = NSTextField(frame: NSRect(x: 20, y: 286, width: 440, height: 24))
        urlField.placeholderString = "smb://server/share"
        urlField.font = .systemFont(ofSize: 13)
        urlField.target = self
        urlField.action = #selector(connect(_:))
        urlField.autoresizingMask = [.width, .minYMargin]
        content.addSubview(urlField)

        let recentLabel = NSTextField(labelWithString: "최근 사용한 서버")
        recentLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        recentLabel.textColor = .secondaryLabelColor
        recentLabel.frame = NSRect(x: 20, y: 258, width: 200, height: 16)
        recentLabel.autoresizingMask = [.minYMargin]
        content.addSubview(recentLabel)

        let clearBtn = NSButton(title: "모두 지우기", target: self, action: #selector(clearRecents(_:)))
        clearBtn.bezelStyle = .inline
        clearBtn.controlSize = .small
        clearBtn.font = .systemFont(ofSize: 11)
        clearBtn.frame = NSRect(x: 380, y: 256, width: 80, height: 18)
        clearBtn.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(clearBtn)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 70, width: 440, height: 178))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        content.addSubview(scroll)

        recentTable = NSTableView(frame: scroll.bounds)
        recentTable.headerView = nil
        recentTable.rowHeight = 20
        recentTable.intercellSpacing = NSSize(width: 0, height: 0)
        recentTable.allowsMultipleSelection = false
        recentTable.usesAlternatingRowBackgroundColors = true
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        col.title = ""
        col.resizingMask = [.autoresizingMask]
        recentTable.addTableColumn(col)
        recentTable.delegate = self
        recentTable.dataSource = self
        recentTable.doubleAction = #selector(doubleClickedRecent(_:))
        recentTable.target = self
        scroll.documentView = recentTable

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: 36, width: 320, height: 18)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(statusLabel)

        progressIndicator = NSProgressIndicator(frame: NSRect(x: 20, y: 14, width: 16, height: 16))
        progressIndicator.style = .spinning
        progressIndicator.isHidden = true
        progressIndicator.controlSize = .small
        progressIndicator.autoresizingMask = [.maxYMargin]
        content.addSubview(progressIndicator)

        let cancelBtn = NSButton(title: "취소", target: self, action: #selector(cancel(_:)))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"   // Esc
        cancelBtn.frame = NSRect(x: 260, y: 12, width: 90, height: 28)
        cancelBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(cancelBtn)

        connectButton = NSButton(title: "연결", target: self, action: #selector(connect(_:)))
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.frame = NSRect(x: 360, y: 12, width: 100, height: 28)
        connectButton.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(connectButton)
    }

    // MARK: - Actions

    @objc private func cancel(_ sender: Any?) {
        window?.orderOut(nil)
    }

    @objc private func connect(_ sender: Any?) {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else {
            statusLabel.stringValue = "올바른 서버 주소를 입력하세요. (예: smb://server/share)"
            statusLabel.textColor = .systemRed
            return
        }
        statusLabel.stringValue = "\(raw)에 연결 중…"
        statusLabel.textColor = .secondaryLabelColor
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        connectButton.isEnabled = false

        NetworkConnectService.shared.connect(to: url) { [weak self] result in
            guard let self = self else { return }
            self.progressIndicator.stopAnimation(nil)
            self.progressIndicator.isHidden = true
            self.connectButton.isEnabled = true
            switch result {
            case .success(let mounted):
                self.reloadRecent()
                self.window?.orderOut(nil)
                if let first = mounted.first {
                    self.onConnected?(first)
                }
            case .failure(let err):
                self.statusLabel.stringValue = err.localizedDescription
                self.statusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func doubleClickedRecent(_ sender: Any?) {
        let row = recentTable.clickedRow
        let servers = NetworkConnectService.shared.recentServers
        guard row >= 0, row < servers.count else { return }
        urlField.stringValue = servers[row].absoluteString
        connect(sender)
    }

    @objc private func clearRecents(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "최근 사용한 서버 목록을 모두 지우시겠습니까?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "지우기")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            NetworkConnectService.shared.clearRecent()
            reloadRecent()
        }
    }

    private func reloadRecent() {
        recentTable.reloadData()
    }
}

// MARK: - Recent table data

extension ServerConnectDialog: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        NetworkConnectService.shared.recentServers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let servers = NetworkConnectService.shared.recentServers
        guard row < servers.count else { return nil }
        let url = servers[row]
        let identifier = NSUserInterfaceItemIdentifier("recentRow")
        let cell: NSTableCellView = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? {
                let v = NSTableCellView()
                v.identifier = identifier
                let tf = NSTextField(labelWithString: "")
                tf.font = .systemFont(ofSize: 12)
                tf.lineBreakMode = .byTruncatingMiddle
                tf.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(tf)
                v.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: v.centerYAnchor)
                ])
                return v
            }()
        cell.textField?.stringValue = url.absoluteString
        return cell
    }

    func tableView(_ tableView: NSTableView, selectionIndicesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        // Mirror selection into URL field so a single click previews the
        // entry without committing.
        if let row = proposedSelectionIndexes.first {
            let servers = NetworkConnectService.shared.recentServers
            if row < servers.count {
                urlField.stringValue = servers[row].absoluteString
            }
        }
        return proposedSelectionIndexes
    }
}
