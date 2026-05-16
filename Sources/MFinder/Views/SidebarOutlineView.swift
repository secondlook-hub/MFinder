import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Data model

/// Single unified node type for the entire sidebar outline. Hashable +
/// reference-stable representation lets NSOutlineView track expansion and
/// selection across reloads.
enum SidebarItem: Hashable {
    case section(SidebarSection)
    case favoriteRoot(QuickAccessItem)
    case pcRoot(QuickAccessItem)
    case folder(URL)

    var folderURL: URL? {
        switch self {
        case .favoriteRoot(let qa), .pcRoot(let qa): return qa.url
        case .folder(let url): return url
        case .section: return nil
        }
    }

    var isSection: Bool {
        if case .section = self { return true }
        return false
    }
}

enum SidebarSection: String, Hashable {
    case favorites = "즐겨찾기"
    case thisPC    = "내 PC"
    case network   = "네트워크"

    var symbolName: String {
        switch self {
        case .favorites: return "star.fill"
        case .thisPC:    return "desktopcomputer"
        case .network:   return "network"
        }
    }

    var symbolColor: NSColor {
        switch self {
        case .favorites: return NSColor.systemYellow
        case .thisPC:    return NSColor(red: 0.0, green: 0.47, blue: 0.84, alpha: 1.0)
        case .network:   return .gray
        }
    }
}

// MARK: - NSViewRepresentable host

/// NSOutlineView-backed sidebar. Replaces the previous SwiftUI tree so that
/// inline rename uses NSOutlineView's built-in `editColumn(...)` mechanism,
/// matching FileTableView and avoiding the focus races inherent to wrapping
/// an NSTextField inside SwiftUI gesture/menu modifiers.
struct SidebarOutlineRepresentable: NSViewRepresentable {
    @ObservedObject var nav: NavigationState
    @ObservedObject var tree: FolderTreeStore
    @ObservedObject var clipboard: ClipboardService = .shared
    @ObservedObject var pinned: PinnedFoldersService = .shared

    func makeCoordinator() -> Coordinator { Coordinator(nav: nav, tree: tree) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white

        let outline = SidebarNSOutlineView()
        outline.coordinator = context.coordinator
        context.coordinator.outlineView = outline

        outline.style = .plain
        outline.indentationPerLevel = 14
        outline.rowHeight = 22
        outline.headerView = nil
        outline.usesAlternatingRowBackgroundColors = false
        outline.gridStyleMask = []
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.backgroundColor = .white
        outline.floatsGroupRows = false
        outline.selectionHighlightStyle = .regular
        outline.autoresizesOutlineColumn = true

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = ""
        col.minWidth = 100
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator

        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy], forLocal: false)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu

        scrollView.documentView = outline

        outline.reloadData()
        // Sections always start expanded except Network (rarely used and empty).
        outline.expandItem(SidebarItem.section(.favorites))
        outline.expandItem(SidebarItem.section(.thisPC))

        context.coordinator.installObservers()
        context.coordinator.applyState()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.applyState()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        let nav: NavigationState
        let tree: FolderTreeStore
        weak var outlineView: NSOutlineView?

        private var cancellables: Set<AnyCancellable> = []
        private var syncedCurrentPath: String = ""
        private var syncedExpanded: Set<URL> = []
        private var syncedChildrenCache: [URL: [URL]] = [:]
        private var syncedPinnedURLs: [URL] = []
        private var syncedRenamingURL: URL?
        private var suppressSelectionNotification = false
        private var volumeMountToken: NSObjectProtocol?
        private var volumeUnmountToken: NSObjectProtocol?

        // Click-after-pause rename — same pattern as FileNSTableView.
        private var pendingRenameRow: Int = -1
        private var renameTimer: Timer?
        /// Live NSEvent monitor that cancels the pending rename if the mouse
        /// moves off the row the user just clicked. Without this, rename
        /// fires regardless of whether the user is actually still hovering.
        private var renameMouseMonitor: Any?

        // Active rename target so controlTextDidEndEditing knows which item
        // was being edited even after the row scrolls or refreshes.
        var activeRenameURL: URL?

        init(nav: NavigationState, tree: FolderTreeStore) {
            self.nav = nav
            self.tree = tree
            super.init()
        }

        deinit {
            renameTimer?.invalidate()
            if let m = renameMouseMonitor {
                NSEvent.removeMonitor(m)
            }
            let ws = NSWorkspace.shared.notificationCenter
            if let t = volumeMountToken   { ws.removeObserver(t) }
            if let t = volumeUnmountToken { ws.removeObserver(t) }
        }

        // The fixed top-level items.
        var rootItems: [SidebarItem] {
            [.section(.favorites), .section(.thisPC), .section(.network)]
        }

        // MARK: Children resolution

        func children(of item: SidebarItem) -> [SidebarItem] {
            switch item {
            case .section(let id):
                switch id {
                case .favorites:
                    _ = PinnedFoldersService.shared.pinnedURLs
                    return FileSystemService.shared.quickAccessLocations().map { .favoriteRoot($0) }
                case .thisPC:
                    return FileSystemService.shared.thisPCLocations().map { .pcRoot($0) }
                case .network:
                    return []
                }
            case .favoriteRoot(let qa), .pcRoot(let qa):
                let kids = tree.children(of: qa.url) ?? []
                return kids.map { .folder($0) }
            case .folder(let url):
                let kids = tree.children(of: url) ?? []
                return kids.map { .folder($0) }
            }
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? SidebarItem else { return rootItems.count }
            return children(of: node).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? SidebarItem else { return rootItems[index] }
            return children(of: node)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? SidebarItem else { return false }
            switch node {
            case .section(let s):
                return s != .network
            case .favoriteRoot, .pcRoot:
                return true   // optimistic; chevron disappears on actual empty load
            case .folder(let url):
                if let cached = tree.children(of: url) {
                    return !cached.isEmpty
                }
                return true
            }
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarItem else { return nil }
            switch node {
            case .section(let id):
                return makeSectionCell(id)
            case .favoriteRoot(let qa):
                return makeQuickAccessCell(qa: qa, isPinned: false)
            case .pcRoot(let qa):
                return makeQuickAccessCell(qa: qa, isPinned: false)
            case .folder(let url):
                return makeFolderCell(url: url)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            SidebarRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? SidebarItem else { return false }
            // Section header rows shouldn't be selectable — they only toggle.
            if case .section = node { return false }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            22
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            // Load children synchronously *before* AppKit asks the data
            // source how many to display, so the expanded view shows the
            // correct rows on first paint instead of an empty branch.
            if let node = item as? SidebarItem, let url = node.folderURL {
                tree.expand(url)
            }
            return true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionNotification, let ov = outlineView else { return }
            // Update the published multi-selection mirror (skipping section
            // header rows that don't have a URL).
            let urls = ov.selectedRowIndexes.compactMap { idx -> URL? in
                guard let node = ov.item(atRow: idx) as? SidebarItem else { return nil }
                return node.folderURL
            }
            if nav.sidebarSelectionURLs != urls {
                nav.sidebarSelectionURLs = urls
            }
            AppFocus.area = .sidebar
            // Only navigate when exactly one row is selected, so extending
            // the selection (Cmd-click / Shift-click) doesn't kick the file
            // list to whichever row was added last.
            guard ov.selectedRowIndexes.count == 1,
                  let row = ov.selectedRowIndexes.first,
                  let node = ov.item(atRow: row) as? SidebarItem else { return }
            switch node {
            case .favoriteRoot(let qa), .pcRoot(let qa):
                if nav.currentURL.standardizedFileURL.path != qa.url.standardizedFileURL.path {
                    nav.navigate(to: qa.url)
                }
                tree.expand(qa.url)
            case .folder(let url):
                if nav.currentURL.standardizedFileURL.path != url.standardizedFileURL.path {
                    nav.navigate(to: url)
                }
                tree.expand(url)
            case .section:
                break
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
            if let url = item.folderURL {
                tree.expand(url)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
            if let url = item.folderURL {
                tree.collapse(url)
            }
        }

        // MARK: - Cell builders

        private func makeSectionCell(_ id: SidebarSection) -> NSView {
            let cell = NSTableCellView()
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: id.symbolName, accessibilityDescription: nil)
            icon.contentTintColor = id.symbolColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: id.rawValue)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = .black
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 14),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func makeQuickAccessCell(qa: QuickAccessItem, isPinned: Bool) -> NSView {
            buildIconLabelCell(symbol: qa.systemSymbol,
                               color: NSColor(red: 0.96, green: 0.78, blue: 0.18, alpha: 1.0),
                               name: qa.name,
                               url: qa.url)
        }

        private func makeFolderCell(url: URL) -> NSView {
            buildIconLabelCell(symbol: "folder.fill",
                               color: NSColor(red: 0.96, green: 0.78, blue: 0.18, alpha: 1.0),
                               name: url.lastPathComponent,
                               url: url)
        }

        private func buildIconLabelCell(symbol: String, color: NSColor, name: String, url: URL) -> NSTableCellView {
            let cell = SidebarLabelCell()
            cell.boundURL = url
            cell.coordinator = self

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = color
            icon.translatesAutoresizingMaskIntoConstraints = false

            let label = SidebarEditableTextField()
            label.stringValue = name
            label.isEditable = false
            label.isSelectable = false
            label.isBezeled = false
            label.drawsBackground = false
            label.font = NSFont.systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.delegate = self
            label.translatesAutoresizingMaskIntoConstraints = false
            // Show "cut" pasteboard state with reduced opacity, like the list view.
            let isCut = ClipboardService.shared.isCut(url)
            label.alphaValue = isCut ? 0.45 : 1.0
            icon.alphaValue = isCut ? 0.45 : 1.0

            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 14),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        // MARK: - State synchronization

        func installObservers() {
            // Reload structure whenever the tree's expansion / children change.
            tree.$expandedURLs
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyState() }
                .store(in: &cancellables)
            tree.$childrenCache
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyState() }
                .store(in: &cancellables)
            // Selection / rename driven by NavigationState.
            nav.$currentURL
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyState() }
                .store(in: &cancellables)
            nav.$renamingURL
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyState() }
                .store(in: &cancellables)
            // Pinned & clipboard affect display only.
            PinnedFoldersService.shared.$pinnedURLs
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyState() }
                .store(in: &cancellables)
            ClipboardService.shared.$stack
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyState() }
                .store(in: &cancellables)

            // Mount / unmount notifications arrive on NSWorkspace's own
            // notification center, not the default one. Reload just the
            // 내 PC section so newly-mounted DMGs / external disks show up
            // immediately and unmounted ones disappear without a relaunch.
            let ws = NSWorkspace.shared.notificationCenter
            volumeMountToken = ws.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reloadThisPCSection()
            }
            volumeUnmountToken = ws.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reloadThisPCSection()
            }
        }

        private func reloadThisPCSection() {
            guard let ov = outlineView else { return }
            let item = SidebarItem.section(.thisPC)
            ov.reloadItem(item, reloadChildren: true)
            ov.expandItem(item)
        }

        func applyState() {
            guard let ov = outlineView else { return }

            // Critical: while an inline rename is in progress, do not touch
            // the outline view's data — reloadData / expand calls would
            // destroy the active field editor and we'd lose the user's edit
            // (this is the exact problem the SwiftUI version had).
            let isRenameActive = nav.renamingURL != nil

            let childrenChanged = syncedChildrenCache != tree.childrenCache
            let expansionChanged = syncedExpanded != tree.expandedURLs
            let pinnedChanged = syncedPinnedURLs != PinnedFoldersService.shared.pinnedURLs

            // Pinning / unpinning a folder updates the favorites section
            // (built from quickAccessLocations()), so reload just that node
            // when the pin set changes. Doing this independently of the
            // childrenCache reload path avoids tearing the whole tree apart.
            if !isRenameActive && pinnedChanged {
                ov.reloadItem(SidebarItem.section(.favorites), reloadChildren: true)
                ov.expandItem(SidebarItem.section(.favorites))
                syncedPinnedURLs = PinnedFoldersService.shared.pinnedURLs
            }

            if !isRenameActive && childrenChanged {
                ov.beginUpdates()
                ov.reloadData()
                ov.expandItem(SidebarItem.section(.favorites))
                ov.expandItem(SidebarItem.section(.thisPC))
                // Re-expand all known expanded URLs. Sort by depth so each
                // parent is expanded before its children are looked up.
                let urls = tree.expandedURLs.sorted {
                    $0.pathComponents.count < $1.pathComponents.count
                }
                for url in urls {
                    if let item = locateItem(for: url) {
                        ov.expandItem(item)
                    }
                }
                ov.endUpdates()
                syncedExpanded = tree.expandedURLs
                syncedChildrenCache = tree.childrenCache
            } else if !isRenameActive && expansionChanged {
                // Cheap path: only expansion set changed (programmatic
                // navigation expanded ancestors via tree.ensureVisible).
                // Apply diffs without reloading data.
                let added = tree.expandedURLs.subtracting(syncedExpanded)
                let removed = syncedExpanded.subtracting(tree.expandedURLs)
                for url in added.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }) {
                    if let item = locateItem(for: url), !ov.isItemExpanded(item) {
                        ov.expandItem(item)
                    }
                }
                for url in removed {
                    if let item = locateItem(for: url), ov.isItemExpanded(item) {
                        ov.collapseItem(item)
                    }
                }
                syncedExpanded = tree.expandedURLs
            }

            syncSelection()

            // Start an inline rename when nav.renamingURL was just set to a
            // URL we can locate. editColumn handles focus + field editor
            // through AppKit, matching FileTableView's reliable mechanism.
            if let renameURL = nav.renamingURL, syncedRenamingURL != renameURL {
                if let item = locateItem(for: renameURL), let row = rowIndex(for: item) {
                    syncedRenamingURL = renameURL
                    activeRenameURL = renameURL
                    DispatchQueue.main.async { [weak self] in
                        self?.beginEdit(at: row, item: item)
                    }
                }
            } else if nav.renamingURL == nil {
                syncedRenamingURL = nil
            }
        }

        func syncSelection() {
            guard let ov = outlineView else { return }
            let curPath = nav.currentURL.standardizedFileURL.path
            guard curPath != syncedCurrentPath else { return }
            syncedCurrentPath = curPath
            if let item = locateItem(for: nav.currentURL), let row = rowIndex(for: item) {
                // Preserve a user-built multi-selection if it already
                // contains the new currentURL — only the visible scroll
                // moves. Otherwise reset to just that single row.
                if ov.selectedRowIndexes.contains(row) {
                    ov.scrollRowToVisible(row)
                    return
                }
                suppressSelectionNotification = true
                ov.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                ov.scrollRowToVisible(row)
                suppressSelectionNotification = false
            }
        }

        // MARK: - URL → outline item resolution

        /// Find the SidebarItem currently shown that matches the given URL.
        /// First match priority: an existing `.folder(url)` row anywhere in
        /// the visible outline; otherwise a top-level favorite / pcRoot
        /// whose URL matches.
        func locateItem(for url: URL) -> SidebarItem? {
            guard let ov = outlineView else { return nil }
            let target = url.standardizedFileURL.path
            for i in 0..<ov.numberOfRows {
                guard let node = ov.item(atRow: i) as? SidebarItem else { continue }
                if let nodeURL = node.folderURL,
                   nodeURL.standardizedFileURL.path == target {
                    return node
                }
            }
            return nil
        }

        func rowIndex(for item: SidebarItem) -> Int? {
            guard let ov = outlineView else { return nil }
            let row = ov.row(forItem: item)
            return row >= 0 ? row : nil
        }

        // MARK: - Inline rename

        func beginEdit(at row: Int, item: SidebarItem) {
            guard let ov = outlineView, row >= 0, row < ov.numberOfRows else { return }
            guard let url = item.folderURL else { return }
            guard let cell = ov.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let tf = cell.textField else { return }
            ov.scrollRowToVisible(row)
            tf.isEditable = true
            tf.isSelectable = true
            tf.isBezeled = true
            tf.bezelStyle = .squareBezel
            tf.drawsBackground = true
            tf.backgroundColor = .textBackgroundColor
            tf.focusRingType = .default
            tf.stringValue = url.lastPathComponent
            activeRenameURL = url
            ov.editColumn(0, row: row, with: nil, select: false)
            // Place caret at end so the original name stays visible (Finder
            // selects all; we prefer Windows-style caret-at-end for folders).
            if let editor = tf.window?.fieldEditor(true, for: tf) as? NSTextView {
                editor.selectedRange = NSRange(location: tf.stringValue.count, length: 0)
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField,
                  let ov = outlineView else { return }
            let row = ov.row(for: tf)
            defer {
                tf.isEditable = false
                tf.isSelectable = false
                tf.isBezeled = false
                tf.drawsBackground = false
                tf.backgroundColor = nil
                tf.focusRingType = .none
                if nav.renamingURL != nil {
                    nav.renamingURL = nil
                }
                syncedRenamingURL = nil
                activeRenameURL = nil
            }
            guard row >= 0, let originalURL = activeRenameURL else {
                if let url = activeRenameURL { tf.stringValue = url.lastPathComponent }
                return
            }
            let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if newName.isEmpty || newName == originalURL.lastPathComponent {
                tf.stringValue = originalURL.lastPathComponent
                return
            }
            let parent = originalURL.deletingLastPathComponent()
            let dst = parent.appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: originalURL, to: dst)
                tree.reloadChildren(of: parent)
                if originalURL.standardizedFileURL == nav.currentURL.standardizedFileURL {
                    nav.navigate(to: dst)
                } else {
                    nav.reload()
                }
            } catch {
                tf.stringValue = originalURL.lastPathComponent
                presentAlert("이름 바꾸기 실패", error.localizedDescription)
            }
        }

        // MARK: - Click-after-pause rename (Finder/Explorer parity)

        func handleMouseDown(event: NSEvent) {
            guard let ov = outlineView else { return }
            let point = ov.convert(event.locationInWindow, from: nil)
            let row = ov.row(at: point)
            let isPlain = event.clickCount == 1 &&
                event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            let onSelectedRow = row >= 0 && ov.selectedRow == row
            let renameable: Bool = {
                guard let node = ov.item(atRow: row) as? SidebarItem else { return false }
                switch node {
                case .folder: return true
                default:      return false
                }
            }()
            cancelPendingRename()
            guard isPlain && onSelectedRow && renameable else { return }
            pendingRenameRow = row
            let rowRect = ov.rect(ofRow: row)
            // Make sure mouseMoved events actually reach us so the monitor
            // below can fire while the user hovers without dragging.
            ov.window?.acceptsMouseMovedEvents = true
            // Cancel the rename if the mouse leaves the originally-clicked
            // row (Finder/Explorer behavior — the user has to stay put).
            renameMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self, weak ov] event in
                guard let self = self, let ov = ov else { return event }
                let p = ov.convert(event.locationInWindow, from: nil)
                if !rowRect.contains(p) {
                    self.cancelPendingRename()
                }
                return event
            }
            let delay = NSEvent.doubleClickInterval + 0.4
            renameTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self,
                          let ov = self.outlineView else { return }
                    defer { self.cancelPendingRename() }
                    guard self.pendingRenameRow == row,
                          ov.selectedRow == row,
                          let item = ov.item(atRow: row) as? SidebarItem,
                          let url = item.folderURL else { return }
                    // Final check at fire time — the mouse must still be on
                    // the row. The move monitor cancels eagerly, but this
                    // also covers the case where the window lost mouseMoved
                    // delivery for some reason.
                    if let win = ov.window {
                        let screen = NSEvent.mouseLocation
                        let inWin = win.convertPoint(fromScreen: screen)
                        let inView = ov.convert(inWin, from: nil)
                        guard rowRect.contains(inView) else { return }
                    }
                    self.nav.renamingURL = url
                }
            }
        }

        private func cancelPendingRename() {
            renameTimer?.invalidate()
            renameTimer = nil
            pendingRenameRow = -1
            if let m = renameMouseMonitor {
                NSEvent.removeMonitor(m)
                renameMouseMonitor = nil
            }
        }

        // MARK: - Context menu

        /// Returns the URLs the right-click menu should operate on. If the
        /// clicked row is one of the already-selected rows, the whole
        /// selection is targeted; otherwise just the clicked row.
        private func actionURLs(for clickedURL: URL) -> [URL] {
            guard let ov = outlineView else { return [clickedURL] }
            let selected = ov.selectedRowIndexes.compactMap { idx -> URL? in
                guard let node = ov.item(atRow: idx) as? SidebarItem else { return nil }
                return node.folderURL
            }
            let clickedStd = clickedURL.standardizedFileURL
            if selected.contains(where: { $0.standardizedFileURL == clickedStd }), selected.count > 1 {
                return selected
            }
            return [clickedURL]
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let ov = outlineView else { return }
            let row = ov.clickedRow
            guard row >= 0, let node = ov.item(atRow: row) as? SidebarItem else { return }
            switch node {
            case .section(let s):
                let title = ov.isItemExpanded(node) ? "접기" : "확장"
                menu.addItem(blockItem(title) { [weak ov, weak self] in
                    guard let ov = ov, let self = self else { return }
                    if ov.isItemExpanded(node) {
                        ov.collapseItem(node)
                    } else {
                        ov.expandItem(node)
                    }
                    _ = s
                    _ = self
                })
            case .favoriteRoot(let qa), .pcRoot(let qa):
                buildItemMenu(menu, url: qa.url, isFolder: true, isPinnable: true)
            case .folder(let url):
                buildItemMenu(menu, url: url, isFolder: true, isPinnable: true)
            }
        }

        private func buildItemMenu(_ menu: NSMenu, url: URL, isFolder: Bool, isPinnable: Bool) {
            let urls = actionURLs(for: url)
            let isMulti = urls.count > 1
            // Open-in-tab / open-in-new-window stay single-target (the
            // clicked row); spawning N tabs from a multi-selection would be
            // surprising. Same for expand/collapse and rename.
            menu.addItem(blockItem("새 탭에서 열기") {
                NotificationCenter.default.post(name: .mfinderNewTab, object: url)
            })
            menu.addItem(blockItem("새 창에서 열기") {
                FileSystemService.shared.openItem(url)
            })
            if isFolder, !isMulti, let ov = outlineView,
               let item = locateItem(for: url) {
                let title = ov.isItemExpanded(item) ? "접기" : "확장"
                menu.addItem(blockItem(title) {
                    if ov.isItemExpanded(item) {
                        ov.collapseItem(item)
                    } else {
                        ov.expandItem(item)
                    }
                })
            }
            menu.addItem(.separator())
            // Copy / cut respect the multi-selection.
            let copyTitle = isMulti ? "복사 (\(urls.count)개)" : "복사"
            let cutTitle  = isMulti ? "잘라내기 (\(urls.count)개)" : "잘라내기"
            menu.addItem(blockItem(copyTitle) { ClipboardService.shared.copy(urls) })
            menu.addItem(blockItem(cutTitle)  { ClipboardService.shared.cut(urls) })
            // Paste destination must be single — into the right-clicked
            // folder, regardless of how many rows are selected.
            let pasteItem = blockItem("붙여넣기 (이 폴더 안으로)") { [weak self] in
                guard let self = self else { return }
                pasteIntoFolderShared(url, nav: self.nav, tree: self.tree)
            }
            pasteItem.isEnabled = ClipboardService.shared.hasContent
            menu.addItem(pasteItem)
            menu.addItem(blockItem(isMulti ? "바로 가기 만들기 (\(urls.count)개)" : "바로 가기 만들기") { [weak self] in
                guard let self = self else { return }
                for u in urls { self.createAliasInParent(of: u) }
            })
            menu.addItem(.separator())
            // Rename is one folder at a time.
            if !isMulti {
                menu.addItem(blockItem("이름 바꾸기") { [weak self] in
                    AppFocus.area = .sidebar
                    self?.nav.renamingURL = url
                })
            }
            let trashTitle = isMulti ? "휴지통으로 이동 (\(urls.count)개)" : "휴지통으로 이동"
            menu.addItem(blockItem(trashTitle) { [weak self] in
                guard let self = self else { return }
                trashTreeFolders(urls, nav: self.nav, tree: self.tree)
            })
            menu.addItem(.separator())
            // Pinning: when multi-selected, decide by majority — if any of
            // the selected URLs are already pinned, the menu offers "remove
            // from favorites" for all of them; otherwise "add to favorites".
            if isMulti {
                let anyPinned = urls.contains(where: { PinnedFoldersService.shared.isPinned($0) })
                if anyPinned {
                    menu.addItem(blockItem("즐겨찾기에서 제거 (\(urls.count)개)") {
                        for u in urls { PinnedFoldersService.shared.unpin(u) }
                    })
                } else if isPinnable {
                    menu.addItem(blockItem("즐겨찾기에 추가 (\(urls.count)개)") {
                        for u in urls { PinnedFoldersService.shared.pin(u) }
                    })
                }
            } else {
                if PinnedFoldersService.shared.isPinned(url) {
                    menu.addItem(blockItem("즐겨찾기에서 제거") {
                        PinnedFoldersService.shared.unpin(url)
                    })
                } else if isPinnable {
                    menu.addItem(blockItem("즐겨찾기에 추가") {
                        PinnedFoldersService.shared.pin(url)
                    })
                }
            }
            menu.addItem(.separator())
            menu.addItem(blockItem("새로 고침") { [weak self] in
                guard let self = self else { return }
                for u in urls { self.tree.reloadChildren(of: u) }
            })
            menu.addItem(blockItem(isMulti ? "Finder에서 보기 (\(urls.count)개)" : "Finder에서 보기") {
                for u in urls { FileSystemService.shared.revealInFinder(u) }
            })
            if !isMulti, Self.isEjectableVolume(url) {
                menu.addItem(.separator())
                menu.addItem(blockItem("꺼내기") { [weak self] in
                    self?.eject(url)
                })
            }
            menu.addItem(.separator())
            menu.addItem(blockItem(isMulti ? "경로 복사 (\(urls.count)개)" : "경로 복사") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(urls.map { $0.path }.joined(separator: "\n"), forType: .string)
            })
        }

        /// True if `url` is a mounted volume that can be unmounted/ejected —
        /// i.e. it's directly under `/Volumes/` and isn't the boot disk.
        private static func isEjectableVolume(_ url: URL) -> Bool {
            let std = url.standardizedFileURL
            let path = std.path
            // Directly under /Volumes/.
            guard path.hasPrefix("/Volumes/"),
                  std.deletingLastPathComponent().path == "/Volumes" else {
                return false
            }
            // Skip the boot disk's `/Volumes/Macintosh HD` symlink.
            let vals = try? std.resourceValues(forKeys: [.volumeIsRootFileSystemKey])
            if vals?.volumeIsRootFileSystem == true { return false }
            return true
        }

        private func eject(_ url: URL) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                // didUnmountNotification handles the sidebar refresh; if the
                // currently-shown folder lived on the volume, fall back to
                // the home directory so the file list doesn't keep pointing
                // at a vanished path.
                if nav.currentURL.path.hasPrefix(url.path + "/") ||
                   nav.currentURL.standardizedFileURL == url.standardizedFileURL {
                    nav.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                }
            } catch {
                presentAlert("꺼내기 실패", error.localizedDescription)
            }
        }

        private func createAliasInParent(of folder: URL) {
            let parent = folder.deletingLastPathComponent()
            let dst = uniqueChildName(in: parent, base: "\(folder.lastPathComponent) 바로 가기")
            do {
                try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: folder)
                tree.reloadChildren(of: parent)
                if parent.standardizedFileURL == nav.currentURL.standardizedFileURL {
                    nav.reload(thenSelect: [dst])
                }
            } catch {
                presentAlert("바로 가기 만들기 실패", error.localizedDescription)
            }
        }

        private func uniqueChildName(in dir: URL, base: String) -> URL {
            let fm = FileManager.default
            var candidate = dir.appendingPathComponent(base)
            guard fm.fileExists(atPath: candidate.path) else { return candidate }
            let url = URL(fileURLWithPath: base)
            let nameOnly = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var i = 2
            repeat {
                let new = ext.isEmpty ? "\(nameOnly) (\(i))" : "\(nameOnly) (\(i)).\(ext)"
                candidate = dir.appendingPathComponent(new)
                i += 1
            } while fm.fileExists(atPath: candidate.path)
            return candidate
        }

        private func blockItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.invoke(_:)), keyEquivalent: "")
            let target = MenuActionTarget(action: action)
            item.representedObject = target
            item.target = target
            return item
        }

        // MARK: - Drag & drop (destination)

        func outlineView(_ outlineView: NSOutlineView,
                         validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard let node = item as? SidebarItem, node.folderURL != nil, index == NSOutlineViewDropOnItemIndex else {
                return []
            }
            return NSEvent.modifierFlags.contains(.option) ? .copy : .move
        }

        func outlineView(_ outlineView: NSOutlineView,
                         acceptDrop info: NSDraggingInfo,
                         item: Any?,
                         childIndex index: Int) -> Bool {
            guard let node = item as? SidebarItem, let dst = node.folderURL else { return false }
            let shouldCopy = NSEvent.modifierFlags.contains(.option)
            let pb = info.draggingPasteboard
            guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
            var firstErr: Error?
            var landed: [URL] = []
            for src in urls {
                let stdSrc = src.standardizedFileURL
                let stdDst = dst.standardizedFileURL
                if stdSrc == stdDst { continue }
                if !shouldCopy, stdSrc.deletingLastPathComponent() == stdDst { continue }
                let target = uniqueChildName(in: dst, base: src.lastPathComponent)
                do {
                    if shouldCopy {
                        try FileManager.default.copyItem(at: src, to: target)
                    } else {
                        try FileManager.default.moveItem(at: src, to: target)
                    }
                    landed.append(target)
                } catch {
                    if firstErr == nil { firstErr = error }
                }
            }
            tree.reloadChildren(of: dst)
            if dst.standardizedFileURL == nav.currentURL.standardizedFileURL {
                nav.reload(thenSelect: Set(landed))
            } else {
                nav.reload()
            }
            if let err = firstErr, landed.isEmpty {
                presentAlert("드롭 실패", err.localizedDescription)
            }
            return !landed.isEmpty
        }

        // MARK: - Drag (source)

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? SidebarItem, let url = node.folderURL else { return nil }
            return url as NSURL
        }

        // MARK: - Misc helpers

        private func presentAlert(_ title: String, _ message: String) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
    }
}

// MARK: - NSOutlineView subclass with custom mouseDown + F2 hooks

final class SidebarNSOutlineView: NSOutlineView {
    weak var coordinator: SidebarOutlineRepresentable.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Let AppKit handle the actual selection first so `selectedRow`
        // reflects the click before our handler runs.
        super.mouseDown(with: event)
        coordinator?.handleMouseDown(event: event)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .help])
        // F2 → start rename for the selected row.
        if event.keyCode == 120, mods.isEmpty {
            let row = selectedRow
            guard row >= 0,
                  let item = self.item(atRow: row) as? SidebarItem,
                  let url = item.folderURL else { return }
            coordinator?.nav.renamingURL = url
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Row view (selection style)

final class SidebarRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1.0).setFill()
        bounds.fill()
    }
}

// MARK: - Cell view that can host inline editing

final class SidebarLabelCell: NSTableCellView {
    var boundURL: URL?
    weak var coordinator: SidebarOutlineRepresentable.Coordinator?
}

/// NSTextField that lets clicks fall through to the cell while the field is
/// non-editable (so a click on the name navigates instead of trying to edit).
final class SidebarEditableTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !isEditable { return nil }
        return super.hitTest(point)
    }
}

// MARK: - Menu action wrapper (NSMenuItem can't hold Swift closures directly)

final class MenuActionTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}
