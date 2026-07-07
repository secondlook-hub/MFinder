import SwiftUI
import AppKit

/// Native NSTableView wrapper for the "자세히" (details) view mode.
/// Cells are reused via NSTableView's recycling, columns resize natively,
/// sort indicators are handled by NSTableHeaderView, and selection is
/// bridged back to NavigationState.selectedItems.
struct FileTableView: NSViewRepresentable {
    @ObservedObject var nav: NavigationState
    @ObservedObject private var clipboard = ClipboardService.shared
    @ObservedObject private var themes = ThemeService.shared

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ThemeService.shared.theme.contentBackground.nsColor

        let tableView = FileNSTableView()
        tableView.fileCoordinator = context.coordinator
        tableView.style = .plain
        // Zebra stripes are drawn by FileNSTableRowView from the theme's
        // content colors — the system alternating colors can't be themed.
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // Group headers (그룹화 기준) scroll with content; floating them
        // fights the custom zebra row backgrounds.
        tableView.floatsGroupRows = false
        tableView.headerView = NSTableHeaderView()
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClick(_:))

        addColumn(to: tableView, id: "name",      title: "이름",       width: 260, minWidth: 120, maxWidth: 1200)
        addColumn(to: tableView, id: "modified",  title: "수정한 날짜", width: 160, minWidth: 90,  maxWidth: 320)
        addColumn(to: tableView, id: "type",      title: "유형",       width: 140, minWidth: 70,  maxWidth: 320)
        addColumn(to: tableView, id: "size",      title: "크기",       width: 90,  minWidth: 60,  maxWidth: 200)
        addColumn(to: tableView, id: "created",   title: "만든 날짜",   width: 160, minWidth: 90,  maxWidth: 320)
        addColumn(to: tableView, id: "extension", title: "확장명",     width: 70,  minWidth: 50,  maxWidth: 160)
        addColumn(to: tableView, id: "location",  title: "위치",       width: 260, minWidth: 80,  maxWidth: 800)
        // The "위치" column is meaningful only for search results.
        // (The matched-text preview is rendered inline under the filename in
        // the name column, not in a separate column.)
        tableView.tableColumn(withIdentifier: .init("location"))?.isHidden = true

        // Explorer-style column visibility: only "name" is fixed; the rest
        // follow the persisted header-menu choices.
        let visible = Set(PreferencesService.shared.detailColumns)
        for (id, _) in FileTableView.toggleableColumns {
            tableView.tableColumn(withIdentifier: .init(id))?.isHidden = !visible.contains(id)
        }

        // Right-clicking the column header lists toggleable columns,
        // mirroring Windows Explorer's header context menu.
        let headerMenu = NSMenu()
        headerMenu.autoenablesItems = false
        headerMenu.delegate = context.coordinator
        tableView.headerView?.menu = headerMenu
        context.coordinator.headerMenu = headerMenu

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        // Drag &amp; drop wiring.
        // Source: rows can be dragged to other apps or back into this table.
        // Destination: accept file URLs from anywhere (Finder, this app, other apps).
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)

        // Context menu — built dynamically in menuNeedsUpdate.
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        context.coordinator.tableView = tableView
        scrollView.documentView = tableView
        return scrollView
    }

    private func addColumn(to tableView: NSTableView, id: String, title: String,
                           width: CGFloat, minWidth: CGFloat, maxWidth: CGFloat) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        col.minWidth = minWidth
        col.maxWidth = maxWidth
        col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        tableView.addTableColumn(col)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        let coord = context.coordinator
        coord.parent = self

        // Theme / font sync — cells pull colors and fonts from ThemeService
        // while being configured, so a change just needs backgrounds + reload.
        let theme = themes.theme
        let fontChanged = coord.lastFontSize != themes.fontSize
        let themeChanged = coord.lastTheme != theme
        if themeChanged {
            coord.lastTheme = theme
            scrollView.backgroundColor = theme.contentBackground.nsColor
            tableView.backgroundColor = theme.contentBackground.nsColor
        }
        if fontChanged { coord.lastFontSize = themes.fontSize }

        // Apply search state BEFORE reloadData so cells built by the reload see
        // the current searchQuery/searchRoot. Doing this after the reload meant
        // cells were built with the previous search state and snippets only
        // appeared after the next data-version bump (i.e. when Spotlight returns).
        let inSearch = !nav.searchText.isEmpty
        let newQuery: String? = inSearch ? nav.searchText : nil
        let newRoot: URL? = inSearch ? nav.currentURL : nil
        let searchStateChanged = coord.searchQuery != newQuery || coord.searchRoot != newRoot
        coord.searchQuery = newQuery
        coord.searchRoot = newRoot

        // Track which URLs are pending as "cut" so we can dim them in the list.
        let newCutSet = Set(clipboard.stack.filter(\.isCut).map(\.url))
        let cutSetChanged = coord.cutURLs != newCutSet
        if cutSetChanged {
            coord.cutURLs = newCutSet
        }

        // Reload when items, search context, grouping, cut highlighting, or
        // styling changed. Assigning coord.items rebuilds the display rows.
        let groupChanged = coord.lastGroupField != nav.groupField
        if coord.lastDataVersion != nav.dataVersion || searchStateChanged || cutSetChanged
            || themeChanged || fontChanged || groupChanged {
            coord.lastDataVersion = nav.dataVersion
            coord.lastGroupField = nav.groupField
            coord.items = nav.filteredItems
            tableView.reloadData()
        }

        // Show/hide the "위치" column based on whether we're showing search
        // results. The matched-text preview is rendered inline under the
        // filename in the name column.
        if let locCol = tableView.tableColumn(withIdentifier: .init("location")) {
            locCol.isHidden = !inSearch
        }
        // Taller rows in search mode to fit the snippet line. Base height
        // follows the user's font size preference.
        let desiredHeight: CGFloat = inSearch ? themes.rowHeight * 2 : themes.rowHeight
        if abs(tableView.rowHeight - desiredHeight) > 0.5 {
            tableView.rowHeight = desiredHeight
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<coord.rows.count))
        }

        // External rename trigger (F2 or menu): when nav.renamingURL is set
        // to a URL we know, start an inline rename for that row. Defer one
        // runloop tick so any in-flight selection sync settles first.
        //
        // Skip when the sidebar tree owns the rename intent — the same URL is
        // often visible in both panes, and editColumn here would steal first
        // responder from the sidebar's RenameTextField, causing it to flicker
        // and disappear via controlTextDidEndEditing.
        if AppFocus.area == .fileList,
           let renameURL = nav.renamingURL,
           coord.lastRenamingURL != renameURL,
           let row = coord.rowIndex(of: renameURL) {
            coord.lastRenamingURL = renameURL
            DispatchQueue.main.async {
                coord.startInlineRename(at: row)
            }
        } else if nav.renamingURL == nil {
            coord.lastRenamingURL = nil
        }

        // Sync selection
        let selectedURLs = nav.selectedItems
        if !selectedURLs.isEmpty || !tableView.selectedRowIndexes.isEmpty {
            var indices = IndexSet()
            for (idx, row) in coord.rows.enumerated() {
                if case .item(let item) = row, selectedURLs.contains(item.url) {
                    indices.insert(idx)
                }
            }
            if tableView.selectedRowIndexes != indices {
                coord.suppressSelectionNotification = true
                tableView.selectRowIndexes(indices, byExtendingSelection: false)
                coord.suppressSelectionNotification = false
                // Scroll newly-set selection into view and take keyboard
                // focus so the user can immediately press Enter / arrow keys
                // / Cmd+C on the just-pasted (or just-dropped) items.
                if let first = indices.first {
                    tableView.scrollRowToVisible(first)
                    // Hand keyboard focus to the table so the user can
                    // immediately use the just-selected row — but only if a
                    // text editor (search bar, inline rename field) isn't
                    // currently active; that would be focus theft.
                    let isTextEditing = (tableView.window?.firstResponder as? NSText) != nil
                    if !isTextEditing, tableView.window?.firstResponder !== tableView {
                        tableView.window?.makeFirstResponder(tableView)
                        AppFocus.area = .fileList
                    }
                }
            }
        }

        // Sync sort indicator on column headers
        let key = sortKey(for: nav.sortField)
        let desc = NSSortDescriptor(key: key, ascending: nav.sortAscending)
        if tableView.sortDescriptors.first?.key != desc.key
            || tableView.sortDescriptors.first?.ascending != desc.ascending {
            coord.suppressSortNotification = true
            tableView.sortDescriptors = [desc]
            // Highlight indicator on the right column
            for col in tableView.tableColumns {
                if col.identifier.rawValue == key {
                    tableView.highlightedTableColumn = col
                    tableView.setIndicatorImage(
                        NSImage(named: nav.sortAscending
                                ? NSImage.Name("NSAscendingSortIndicator")
                                : NSImage.Name("NSDescendingSortIndicator")),
                        in: col)
                } else {
                    tableView.setIndicatorImage(nil, in: col)
                }
            }
            coord.suppressSortNotification = false
        }
    }

    private func sortKey(for field: SortField) -> String {
        switch field {
        case .name:     return "name"
        case .modified: return "modified"
        case .type:     return "type"
        case .size:     return "size"
        case .created:  return "created"
        case .ext:      return "extension"
        }
    }

    /// Columns the user can show/hide from the header context menu, in menu
    /// order. "name" is always visible and "location" is search-managed, so
    /// neither appears here.
    static let toggleableColumns: [(id: String, title: String)] = [
        ("modified",  "수정한 날짜"),
        ("type",      "유형"),
        ("size",      "크기"),
        ("created",   "만든 날짜"),
        ("extension", "확장명"),
    ]
}

// MARK: - Coordinator

extension FileTableView {
    /// One display row: either a bold group header (grouping active) or a file.
    enum TableRow {
        case group(String)
        case item(FileItem)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: FileTableView
        weak var tableView: NSTableView?
        weak var headerMenu: NSMenu?
        var items: [FileItem] = [] {
            didSet { rebuildRows() }
        }
        /// Display rows derived from `items` + the active group field.
        /// All NSTableView row indices refer to THIS array, not `items`.
        private(set) var rows: [TableRow] = []
        var lastGroupField: GroupField = .none
        var lastDataVersion: Int = -1
        var lastTheme: Theme? = nil
        var lastFontSize: CGFloat = -1
        var lastRenamingURL: URL? = nil
        var searchRoot: URL? = nil
        var searchQuery: String? = nil
        var cutURLs: Set<URL> = []
        var suppressSelectionNotification = false
        var suppressSortNotification = false
        let renameFocusWatcher = EditFocusWatcher()

        init(_ parent: FileTableView) { self.parent = parent }

        // MARK: - Row model (grouping)

        func item(at row: Int) -> FileItem? {
            guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return nil }
            return item
        }

        func isGroupRow(_ row: Int) -> Bool {
            guard row >= 0, row < rows.count, case .group = rows[row] else { return false }
            return true
        }

        func rowIndex(of url: URL) -> Int? {
            rows.firstIndex {
                if case .item(let item) = $0 { return item.url == url }
                return false
            }
        }

        /// Rebuilds `rows` from `items`. Grouping is suspended during search
        /// (results span many folders; buckets would be misleading).
        func rebuildRows() {
            let field = parent.nav.groupField
            guard field != .none, searchQuery == nil, !items.isEmpty else {
                rows = items.map { .item($0) }
                return
            }
            // Stable bucketing: items keep their sorted order inside groups.
            var order: [String] = []
            var rank: [String: Int] = [:]
            var buckets: [String: [FileItem]] = [:]
            for item in items {
                let key = Self.groupKey(for: item, field: field)
                if buckets[key.label] == nil {
                    order.append(key.label)
                    rank[key.label] = key.rank
                    buckets[key.label] = []
                }
                buckets[key.label]?.append(item)
            }
            order.sort {
                let (r0, r1) = (rank[$0] ?? 0, rank[$1] ?? 0)
                if r0 != r1 { return r0 < r1 }
                return $0.localizedStandardCompare($1) == .orderedAscending
            }
            var built: [TableRow] = []
            for label in order {
                let members = buckets[label] ?? []
                built.append(.group("\(label) (\(members.count))"))
                built.append(contentsOf: members.map { .item($0) })
            }
            rows = built
        }

        /// (rank, label) for one item under `field`. Rank orders buckets
        /// (dates: newest bucket first; sizes: small → large); ties fall back
        /// to alphabetical labels.
        private static func groupKey(for item: FileItem, field: GroupField) -> (rank: Int, label: String) {
            switch field {
            case .none:
                return (0, "")
            case .name:
                guard let first = item.name.first else { return (1, "#") }
                if first.isNumber { return (0, "0 - 9") }
                return (1, String(first).uppercased())
            case .type:
                return (0, item.typeDescription)
            case .ext:
                if item.isDirectory { return (-1, "폴더") }
                return item.ext.isEmpty ? (0, "(확장명 없음)") : (1, item.ext)
            case .modified:
                return dateBucket(item.modificationDate)
            case .created:
                return dateBucket(item.creationDate)
            case .size:
                if item.isDirectory { return (0, "폴더") }
                let kb: Int64 = 1024, mb = kb * 1024, gb = mb * 1024
                switch item.size {
                case 0:                return (1, "비어 있음")
                case ..<(16 * kb):     return (2, "아주 작음 (16KB 미만)")
                case ..<mb:            return (3, "작음 (16KB - 1MB)")
                case ..<(128 * mb):    return (4, "보통 (1MB - 128MB)")
                case ..<gb:            return (5, "큼 (128MB - 1GB)")
                case ..<(4 * gb):      return (6, "아주 큼 (1GB - 4GB)")
                default:               return (7, "매우 큼 (4GB 이상)")
                }
            }
        }

        private static func dateBucket(_ date: Date) -> (rank: Int, label: String) {
            let cal = Calendar.current
            let now = Date()
            if cal.isDateInToday(date) { return (0, "오늘") }
            if cal.isDateInYesterday(date) { return (1, "어제") }
            if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return (2, "이번 주") }
            if let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: now),
               cal.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) { return (3, "지난주") }
            if cal.isDate(date, equalTo: now, toGranularity: .month) { return (4, "이번 달") }
            if cal.isDate(date, equalTo: now, toGranularity: .year) { return (5, "올해") }
            if date > now { return (0, "오늘") }
            return (6, "오래 전")
        }

        @objc func doubleClick(_ sender: Any?) {
            guard let tv = tableView, let item = item(at: tv.clickedRow) else { return }
            open(item)
        }

        fileprivate func open(_ item: FileItem) {
            switch FileSystemService.shared.openAction(for: item.url) {
            case .navigate(let target):
                parent.nav.navigate(to: target)
            case .openFile(let target):
                FileSystemService.shared.openItem(target)
            case .broken(let url):
                let alert = NSAlert()
                alert.messageText = "열 수 없습니다"
                alert.informativeText = "\(url.lastPathComponent)이(가) 가리키는 대상을 찾을 수 없습니다 (끊어진 바로 가기)."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "확인")
                alert.runModal()
            }
        }

        // MARK: - Cut / Copy / Paste / Delete (driven by FileNSTableView responder overrides)

        func performCut() {
            let urls = currentSelectedURLs()
            guard !urls.isEmpty else { return }
            ClipboardService.shared.cut(urls)
        }

        func performCopy() {
            let urls = currentSelectedURLs()
            guard !urls.isEmpty else { return }
            ClipboardService.shared.copy(urls)
        }

        func performPaste() {
            let nav = parent.nav
            ClipboardService.shared.paste(into: nav.currentURL) { [weak self] result in
                switch result {
                case .success(let created):
                    nav.reload(thenSelect: Set(created))
                case .failure(let error):
                    self?.alertError("붙여넣기 실패", message: error.localizedDescription)
                }
            }
        }

        func performDelete() {
            let urls = currentSelectedURLs()
            guard !urls.isEmpty else { return }
            var trashed: [URL] = []
            for url in urls where (try? FileSystemService.shared.moveToTrash(url)) != nil {
                trashed.append(url)
            }
            UndoService.shared.register(.trash(originals: trashed), label: "휴지통으로 이동")
            parent.nav.selectedItems.subtract(urls)
            parent.nav.reload()
        }

        func performOpenSelected() {
            let urls = currentSelectedURLs()
            for url in urls {
                if let item = items.first(where: { $0.url == url }) { open(item) }
            }
        }

        func performSelectAll() {
            guard let tv = tableView else { return }
            tv.selectAll(nil)
        }

        private func currentSelectedURLs() -> [URL] {
            guard let tv = tableView else { return [] }
            return tv.selectedRowIndexes.compactMap { item(at: $0)?.url }
        }

        // MARK: - Inline rename (F2 / click-after-pause)

        /// Switches the cell's NSTextField at column 0 / `row` into edit mode
        /// and begins editing. Selects the basename (excluding extension) so the user
        /// can replace the name without disturbing the extension, matching Finder.
        func startInlineRename(at row: Int) {
            guard let tv = tableView, let item = item(at: row) else { return }
            guard let cell = tv.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let tf = cell.textField else { return }
            tf.isEditable = true
            tf.isSelectable = true
            tf.isBezeled = true
            tf.bezelStyle = .squareBezel
            tf.drawsBackground = true
            tf.backgroundColor = .textBackgroundColor
            tf.focusRingType = .default
            tv.scrollRowToVisible(row)
            tv.editColumn(0, row: row, with: nil, select: true)
            // End the edit if focus leaves the app/window — forcing the table
            // back to first responder runs the normal commit/cancel path.
            renameFocusWatcher.begin(window: tv.window) { [weak tv] in
                guard let tv, tv.window?.firstResponder is NSText else { return }
                tv.window?.makeFirstResponder(tv)
            }
            // After editColumn, the field editor is active. Select the basename only for files.
            if !item.isDirectory,
               let dotRange = item.name.range(of: ".", options: .backwards),
               let editor = tf.window?.fieldEditor(true, for: tf) as? NSTextView {
                let basenameLength = item.name.distance(from: item.name.startIndex, to: dotRange.lowerBound)
                editor.selectedRange = NSRange(location: 0, length: basenameLength)
            }
        }

        /// Invoked by FileNSTableView when keyDown for F2 fires.
        func renameSelectedFromKeyboard() {
            guard let tv = tableView else { return }
            let sel = tv.selectedRowIndexes
            guard sel.count == 1, let row = sel.first else { return }
            startInlineRename(at: row)
        }
    }
}

// MARK: - Custom row view providing Win11-style light gray selection

/// Replaces NSTableView's default system-blue selection with the theme's
/// subtle selection fill that doesn't fight the yellow snippet highlight.
/// interiorBackgroundStyle stays `.normal` so cell text keeps its themed
/// color instead of getting inverted to white as the system would do for an
/// emphasized blue selection. Also draws the theme-derived zebra stripe
/// (system alternating colors can't be themed, so we own the background).
final class FileNSTableRowView: NSTableRowView {
    var zebraColor: NSColor?

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        if let zebra = zebraColor {
            zebra.setFill()
            dirtyRect.fill()
        } else {
            super.drawBackground(in: dirtyRect)
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let theme = ThemeService.shared.theme
        // Slightly stronger when the table view has focus, lighter otherwise —
        // matches Win11 behaviour where an unfocused selection is more muted.
        let color = isEmphasized
            ? theme.selectionEmphasized.nsColor
            : theme.selection.nsColor
        color.setFill()
        let inset = bounds.insetBy(dx: 2, dy: 0)
        NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3).fill()
    }
}

// MARK: - NSTableView subclass that handles ⌘X / ⌘C / ⌘V / Delete / Enter / F2 / click-rename

final class FileNSTableView: NSTableView, NSMenuItemValidation {
    weak var fileCoordinator: FileTableView.Coordinator?

    private var renameTimer: Timer?
    private var pendingRenameRow: Int = -1

    override var acceptsFirstResponder: Bool { true }

    // cut:/copy:/paste:/delete: aren't on NSTableView's responder API by default,
    // so we declare them fresh with @objc to expose them as responder actions.
    // The standard Edit menu's items dispatch by selector through the responder chain.
    @objc func cut(_ sender: Any?)    { fileCoordinator?.performCut() }
    @objc func copy(_ sender: Any?)   { fileCoordinator?.performCopy() }
    @objc func paste(_ sender: Any?)  { fileCoordinator?.performPaste() }
    @objc func delete(_ sender: Any?) { fileCoordinator?.performDelete() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(cut(_:)), #selector(copy(_:)):
            return !selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return ClipboardService.shared.hasContent
        case #selector(delete(_:)):
            return !selectedRowIndexes.isEmpty
        default:
            return true
        }
    }

    override func keyDown(with event: NSEvent) {
        // Note: ⌫ / F2 / Space are intercepted by AppDelegate's global key monitor
        // and dispatched via notifications; they never reach this method.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty {
            // 36 = return, 76 = numpad enter → open
            if event.keyCode == 36 || event.keyCode == 76 {
                fileCoordinator?.performOpenSelected()
                return
            }
        }
        super.keyDown(with: event)
    }

    /// Finder-style: clicking on an already-selected single row, after the
    /// double-click window has passed, starts an inline rename.
    /// Stops a queued click-and-pause rename (e.g. when a drag begins).
    func cancelPendingRename() {
        renameTimer?.invalidate()
        renameTimer = nil
        pendingRenameRow = -1
    }

    override func mouseDown(with event: NSEvent) {
        AppFocus.area = .fileList
        // Cancel any pending rename when a new click occurs (e.g. double-click).
        renameTimer?.invalidate()
        renameTimer = nil

        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let alreadySelectedAndSingle = row >= 0 &&
            selectedRowIndexes == IndexSet(integer: row)
        let plainClick = event.clickCount == 1 &&
            event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty

        if plainClick && alreadySelectedAndSingle {
            // Capture the row; if a 2nd click arrives within doubleClickInterval,
            // mouseDown will run again and invalidate this timer.
            pendingRenameRow = row
            let delay = NSEvent.doubleClickInterval + 0.25
            renameTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                // Timer fires on the runloop that scheduled it — always main here.
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    if self.pendingRenameRow == row,
                       self.selectedRowIndexes == IndexSet(integer: row) {
                        self.fileCoordinator?.startInlineRename(at: row)
                    }
                    self.pendingRenameRow = -1
                }
            }
        } else {
            pendingRenameRow = -1
        }

        super.mouseDown(with: event)
    }
}

extension FileTableView.Coordinator: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSortNotification, let desc = tableView.sortDescriptors.first else { return }
        let field: SortField
        switch desc.key {
        case "name":      field = .name
        case "modified":  field = .modified
        case "type":      field = .type
        case "size":      field = .size
        case "created":   field = .created
        case "extension": field = .ext
        default: return
        }
        parent.nav.applySort(field: field, ascending: desc.ascending)
    }

    // MARK: Drag source — let users drag rows out to Finder/other apps/back into MFinder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let item = item(at: row) else { return nil }
        // A drag is starting — cancel the click-and-pause rename timer so it
        // can't fire mid-drag and open a stray edit field.
        (tableView as? FileNSTableView)?.cancelPendingRename()
        return item.url as NSURL
    }

    // MARK: Drop destination — accept file drops from anywhere

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        // Determine drop target folder. `row` arrives as -1 for drops on
        // the empty area, and AppKit can occasionally hand us a stale row
        // index right after an FSEvent-triggered reload shrank the list —
        // item(at:) checks bounds and skips group rows.
        let rowItem = op == .on ? item(at: row) : nil
        let targetURL: URL? = (rowItem?.isDirectory == true)
            ? rowItem?.url
            : parent.nav.currentURL

        guard let dst = targetURL else { return [] }

        // Read the dragged URLs (best-effort) to reject self-drops.
        let pb = info.draggingPasteboard
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] {
            // Don't allow dropping an item onto itself or into its own parent
            // (that would be a no-op move).
            let dstStd = dst.standardizedFileURL
            if urls.contains(where: { $0.standardizedFileURL == dstStd
                                   || $0.deletingLastPathComponent().standardizedFileURL == dstStd && op != .on }) {
                if op != .on { /* drop on same dir → no-op, but allow copy */ }
            }
            if urls.contains(where: { $0.standardizedFileURL == dstStd }) {
                return []
            }
        }

        if op == .on {
            // Highlight the row.
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        } else {
            // Drop into the empty area / between rows → current folder
            tableView.setDropRow(-1, dropOperation: .above)
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
              !urls.isEmpty else { return false }

        let dst: URL
        if op == .on, let rowItem = item(at: row), rowItem.isDirectory {
            dst = rowItem.url
        } else {
            dst = parent.nav.currentURL
        }

        // Source operation mask + held modifier flags determine move vs copy.
        // macOS convention: holding Option forces .copy; holding Cmd forces .move.
        let mods = NSEvent.modifierFlags
        let mask = info.draggingSourceOperationMask
        let shouldMove: Bool = {
            if mods.contains(.option) { return false }
            if mods.contains(.command) { return true }
            // Default: same-volume = move, cross-volume = copy. Cheap approximation:
            // if source dirs live under the destination's volume, prefer move.
            if mask.contains(.move) && !mask.contains(.copy) { return true }
            // Within-app dragging defaults to move; from Finder defaults to copy.
            let isInternal = (info.draggingSource as? NSTableView) === tableView
            return isInternal
        }()

        // Count overwrite conflicts up front so each dialog can offer a
        // blanket answer for the rest (same UX as clipboard paste).
        var conflictsLeft = urls.filter { src in
            guard src.standardizedFileURL != dst.standardizedFileURL else { return false }
            let plainTarget = dst.appendingPathComponent(src.lastPathComponent)
            return plainTarget.standardizedFileURL != src.standardizedFileURL
                && FileManager.default.fileExists(atPath: plainTarget.path)
        }.count
        var blanket: FileConflictChoice?

        var ops: [FileOperation] = []
        for src in urls {
            // Skip self-drop or into own parent.
            if src.standardizedFileURL == dst.standardizedFileURL { continue }
            let plainTarget = dst.appendingPathComponent(src.lastPathComponent)
            let sameLocation = plainTarget.standardizedFileURL == src.standardizedFileURL
            let target: URL
            if sameLocation {
                // Dropped back into its own folder: a move is a no-op; a copy
                // duplicates rather than overwriting the source onto itself.
                if shouldMove { continue }
                target = uniqueDestinationName(src.lastPathComponent, in: dst)
            } else {
                // A same-named item at the destination prompts 덮어쓰기/건너뛰기/취소.
                if FileManager.default.fileExists(atPath: plainTarget.path) {
                    conflictsLeft -= 1
                    let choice = blanket ?? askFileConflict(name: src.lastPathComponent,
                                                            remainingConflicts: conflictsLeft,
                                                            blanket: &blanket)
                    if choice == .skip { continue }
                    if choice == .cancel { break }
                    try? FileManager.default.removeItem(at: plainTarget)
                }
                target = plainTarget
            }
            ops.append(FileOperation(src: src, dst: target, isMove: shouldMove))
        }
        guard !ops.isEmpty else { return false }

        // The copy/move runs in the background with a progress panel; reload
        // and select once it lands.
        let nav = parent.nav
        FileOperationService.shared.perform(ops, title: shouldMove ? "이동 중…" : "복사 중…") { [weak self] done, err in
            let landed = done.map(\.dst)
            if shouldMove {
                UndoService.shared.register(.move(pairs: done.map { (from: $0.src, to: $0.dst) }),
                                            label: "이동")
            } else {
                UndoService.shared.register(.create(urls: landed), label: "복사")
            }
            // If we dropped into the current folder, reload + select new items.
            if dst.standardizedFileURL == nav.currentURL.standardizedFileURL {
                nav.reload(thenSelect: Set(landed))
            } else {
                nav.reload()
            }
            if let err, landed.isEmpty {
                self?.alertError("드롭 실패", message: err.localizedDescription)
            }
        }
        return true
    }

    private func uniqueDestinationName(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let url = URL(fileURLWithPath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            i += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

extension FileTableView.Coordinator: NSTableViewDelegate {
    /// Group header rows: full-width bold labels, not selectable.
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        isGroupRow(row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !isGroupRow(row)
    }

    /// Type-ahead: typing jumps to the next matching filename.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?,
                   row: Int) -> String? {
        guard tableColumn == nil || tableColumn?.identifier.rawValue == "name" else { return nil }
        return item(at: row)?.name
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < rows.count else { return nil }
        if case .group(let label) = rows[row] {
            return reusableGroupCell(label, tableView: tableView)
        }
        guard let col = tableColumn, case .item(let item) = rows[row] else { return nil }
        let cell: NSTableCellView?
        switch col.identifier.rawValue {
        case "name":     cell = reusableNameCell(for: item, tableView: tableView)
        case "modified": cell = reusableTextCell(item.modificationString, alignment: .left, id: "modCell", tableView: tableView)
        case "type":     cell = reusableTextCell(item.typeDescription,    alignment: .left, id: "typeCell", tableView: tableView)
        case "size":     cell = reusableTextCell(item.sizeString,         alignment: .right, id: "sizeCell", tableView: tableView)
        case "created":  cell = reusableTextCell(item.creationString,     alignment: .left, id: "createdCell", tableView: tableView)
        case "extension": cell = reusableTextCell(item.ext,               alignment: .left, id: "extCell", tableView: tableView)
        case "location": cell = reusableTextCell(relativeLocationLabel(for: item), alignment: .left, id: "locCell", tableView: tableView)
        default:         cell = nil
        }
        // Dim non-name cells when their row's URL is a pending "cut" item.
        // The name cell handles its own alpha because it owns both an image
        // and a stacked snippet label.
        if let cell = cell, col.identifier.rawValue != "name" {
            let dimmed: CGFloat = cutURLs.contains(item.url.standardizedFileURL) ? 0.5 : 1.0
            cell.textField?.alphaValue = dimmed
        }
        return cell
    }

    /// Builds an attributed snippet with every include-token highlighted in
    /// light yellow + bold. Case-insensitive, multi-occurrence per token.
    private func highlightedSnippet(_ snippet: String, tokens: [String]) -> NSAttributedString {
        let theming = ThemeService.shared
        let attr = NSMutableAttributedString(string: snippet, attributes: [
            .font: NSFont.systemFont(ofSize: theming.snippetFontSize),
            .foregroundColor: theming.theme.secondaryText.nsColor
        ])
        let ns = snippet as NSString
        let bg = NSColor(red: 1.0, green: 0.92, blue: 0.5, alpha: 0.85)
        let bold = NSFont.systemFont(ofSize: theming.snippetFontSize, weight: .semibold)
        for token in tokens where !token.isEmpty {
            var searchRange = NSRange(location: 0, length: ns.length)
            while searchRange.location < ns.length {
                let match = ns.range(of: token, options: .caseInsensitive, range: searchRange)
                guard match.location != NSNotFound else { break }
                attr.addAttribute(.backgroundColor, value: bg, range: match)
                attr.addAttribute(.font, value: bold, range: match)
                attr.addAttribute(.foregroundColor, value: NSColor.black, range: match)
                let next = match.location + match.length
                if next >= ns.length { break }
                searchRange = NSRange(location: next, length: ns.length - next)
            }
        }
        return attr
    }

    /// Formats the parent folder path relative to the search root so search
    /// results show "src ▸ models" rather than the full absolute path.
    /// Falls back to the absolute path when the file is outside the search root.
    private func relativeLocationLabel(for item: FileItem) -> String {
        guard let root = searchRoot?.standardizedFileURL else { return "" }
        let parentURL = item.url.deletingLastPathComponent().standardizedFileURL
        if parentURL == root {
            return root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        }
        let rootComps = root.pathComponents
        let parentComps = parentURL.pathComponents
        if parentComps.count > rootComps.count,
           Array(parentComps.prefix(rootComps.count)) == rootComps {
            return parentComps.suffix(from: rootComps.count).joined(separator: " ▸ ")
        }
        return parentURL.path
    }

    private func reusableNameCell(for item: FileItem, tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("nameCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id

            let img = NSImageView()
            img.translatesAutoresizingMaskIntoConstraints = false
            img.imageScaling = .scaleProportionallyDown
            cell.imageView = img
            cell.addSubview(img)

            // Filename — primary line. Editable mode is flipped on for inline rename.
            // Font/color are (re)applied on every configure pass below so theme
            // and font-size changes restyle recycled cells.
            let tf = NSTextField()
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.isEditable = false
            tf.isSelectable = false
            tf.isBezeled = false
            tf.drawsBackground = false
            tf.backgroundColor = nil
            tf.focusRingType = .none
            tf.lineBreakMode = .byTruncatingTail
            tf.usesSingleLineMode = true
            tf.cell?.truncatesLastVisibleLine = true
            tf.delegate = self
            cell.textField = tf

            // Snippet — secondary line, shown only during search.
            let snippetTF = NSTextField()
            snippetTF.identifier = .init("snippet")
            snippetTF.translatesAutoresizingMaskIntoConstraints = false
            snippetTF.isEditable = false
            snippetTF.isSelectable = false
            snippetTF.isBezeled = false
            snippetTF.drawsBackground = false
            snippetTF.backgroundColor = nil
            snippetTF.lineBreakMode = .byTruncatingTail
            snippetTF.usesSingleLineMode = true
            snippetTF.cell?.truncatesLastVisibleLine = true

            // Vertical stack auto-collapses to the filename when the snippet is hidden,
            // so the same cell works for both 22px normal rows and 44px search rows.
            let stack = NSStackView(views: [tf, snippetTF])
            stack.identifier = .init("nameStack")
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)

            NSLayoutConstraint.activate([
                img.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                img.widthAnchor.constraint(equalToConstant: 16),
                img.heightAnchor.constraint(equalToConstant: 16),
                stack.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        // Reset editable state on reuse (previously-renamed cell shouldn't
        // reappear in edit mode) and re-apply theme styling.
        let theming = ThemeService.shared
        if let tf = cell.textField {
            tf.isEditable = false
            tf.isSelectable = false
            tf.isBezeled = false
            tf.drawsBackground = false
            tf.backgroundColor = nil
            tf.focusRingType = .none
            tf.font = NSFont.systemFont(ofSize: theming.fontSize)
            tf.textColor = theming.theme.text.nsColor
        }
        cell.imageView?.image = item.icon
        cell.textField?.stringValue = item.name
        // Stamp the cell with its URL so async snippet completion can detect
        // when the cell has been recycled for a different row.
        cell.objectValue = item.url

        // Dim cells whose URL is queued as "cut" — visual convention shared
        // with Windows Explorer and Finder.
        let dimmed: CGFloat = cutURLs.contains(item.url.standardizedFileURL) ? 0.5 : 1.0
        cell.imageView?.alphaValue = dimmed
        cell.textField?.alphaValue = dimmed

        // Toggle snippet line visibility based on search state.
        guard let snippetTF = findSnippetField(in: cell) else { return cell }
        snippetTF.font = NSFont.systemFont(ofSize: theming.snippetFontSize)
        snippetTF.textColor = theming.theme.secondaryText.nsColor
        let tokens = parent.nav.searchTokens
        if !tokens.includes.isEmpty {
            snippetTF.isHidden = false
            snippetTF.stringValue = ""
            let targetURL = item.url
            let highlightTokens = tokens.includes
            SearchSnippetService.shared.snippet(for: targetURL, tokens: tokens) { [weak cell, weak snippetTF] snippet in
                guard let cell = cell, let snippetTF = snippetTF,
                      (cell.objectValue as? URL) == targetURL else { return }
                if snippet.isEmpty {
                    snippetTF.stringValue = ""
                } else {
                    snippetTF.attributedStringValue = self.highlightedSnippet(snippet, tokens: highlightTokens)
                }
            }
        } else {
            snippetTF.isHidden = true
            snippetTF.stringValue = ""
        }
        return cell
    }

    private func findSnippetField(in cell: NSTableCellView) -> NSTextField? {
        if let stack = cell.subviews.first(where: { $0.identifier?.rawValue == "nameStack" }) as? NSStackView {
            return stack.arrangedSubviews.first { $0.identifier?.rawValue == "snippet" } as? NSTextField
        }
        return nil
    }

    private func reusableGroupCell(_ label: String, tableView: NSTableView) -> NSTableCellView {
        let nid = NSUserInterfaceItemIdentifier("groupCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: nid, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = nid
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell.textField = tf
            cell.addSubview(tf)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let theming = ThemeService.shared
        cell.textField?.font = NSFont.systemFont(ofSize: theming.fontSize, weight: .bold)
        cell.textField?.textColor = theming.theme.text.nsColor
        cell.textField?.stringValue = label
        return cell
    }

    private func reusableTextCell(_ text: String, alignment: NSTextAlignment, id: String, tableView: NSTableView) -> NSTableCellView {
        let nid = NSUserInterfaceItemIdentifier(id)
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: nid, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = nid
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let theming = ThemeService.shared
        cell.textField?.font = NSFont.systemFont(ofSize: theming.fontSize)
        cell.textField?.textColor = theming.theme.text.nsColor
        cell.textField?.alignment = alignment
        cell.textField?.stringValue = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionNotification, let tv = tableView else { return }
        var sel = Set<URL>()
        for idx in tv.selectedRowIndexes {
            if let item = item(at: idx) { sel.insert(item.url) }
        }
        if parent.nav.selectedItems != sel {
            parent.nav.selectedItems = sel
        }
        // Claim keyboard focus only when the table actually has it. This
        // notification also fires for programmatic selection resets — e.g.
        // the reload right after the user clicks a folder in the sidebar —
        // and unconditionally flipping to .fileList there silently rerouted
        // the sidebar's ⌘C/⌘X/⌘V away from the tree selection.
        if tv.window?.firstResponder === tv {
            AppFocus.area = .fileList
        }
    }

    /// Returns our custom row view so selected rows render in the theme's
    /// selection fill (Win11 style) instead of the default system blue.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = FileNSTableRowView()
        let theme = ThemeService.shared.theme
        // Group headers use the flat content background; item rows keep the
        // zebra stripes (parity by row keeps stripes stable while scrolling).
        rowView.zebraColor = (isGroupRow(row) || row % 2 == 0)
            ? theme.contentBackground.nsColor
            : theme.contentBackgroundAlternate.nsColor
        return rowView
    }
}

// MARK: - Inline rename commit

extension FileTableView.Coordinator: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, let tv = tableView else { return }
        renameFocusWatcher.end()
        defer {
            tf.isEditable = false
            tf.isSelectable = false
            tf.isBezeled = false
            tf.drawsBackground = false
            tf.backgroundColor = nil
            tf.focusRingType = .none
            // Always clear the global rename intent so other listeners (and a
            // future F2/menu trigger) work.
            if parent.nav.renamingURL != nil {
                parent.nav.renamingURL = nil
            }
            lastRenamingURL = nil
        }
        // Find which row this textField belongs to.
        var row = -1
        for r in 0..<rows.count {
            if let cell = tv.view(atColumn: 0, row: r, makeIfNecessary: false) as? NSTableCellView,
               cell.textField === tf {
                row = r
                break
            }
        }
        guard let item = item(at: row) else { return }
        let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newName.isEmpty || newName == item.name {
            tf.stringValue = item.name
            return
        }
        let dst = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: item.url, to: dst)
            UndoService.shared.register(.move(pairs: [(from: item.url, to: dst)]), label: "이름 바꾸기")
            parent.nav.reload(thenSelect: [dst])
        } catch {
            tf.stringValue = item.name
            alertError("이름 바꾸기 실패", message: error.localizedDescription)
        }
    }

    /// Pressing Esc cancels the edit; Tab/Return commit it (commit handled in controlTextDidEndEditing).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if let table = tableView, let tf = control as? NSTextField {
                for r in 0..<rows.count {
                    if let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? NSTableCellView,
                       cell.textField === tf, let item = item(at: r) {
                        tf.stringValue = item.name
                        break
                    }
                }
                table.window?.makeFirstResponder(table)
            }
            return true
        }
        return false
    }
}

// MARK: - NSMenu builder (mirrors SwiftUI file/empty-space menus)

extension FileTableView.Coordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tv = tableView else { return }
        if menu === headerMenu {
            buildHeaderMenu(menu)
            return
        }
        let clicked = tv.clickedRow
        guard let target = item(at: clicked) else {
            // Empty area or a group header row → folder-level menu.
            buildEmptyMenu(menu)
            return
        }
        // If user right-clicked a non-selected row, select only that row.
        if !tv.selectedRowIndexes.contains(clicked) {
            tv.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        let allTargets: [URL] = {
            let urls = tv.selectedRowIndexes.compactMap { item(at: $0)?.url }
            return urls.isEmpty ? [target.url] : urls
        }()
        buildFileMenu(menu, target: target, urls: allTargets)
    }

    // MARK: header menu (column visibility, Explorer-style)

    private func buildHeaderMenu(_ menu: NSMenu) {
        guard let tv = tableView else { return }
        // "name" is always on and can't be toggled off.
        let nameItem = block("이름") {}
        nameItem.state = .on
        nameItem.isEnabled = false
        menu.addItem(nameItem)
        for (id, title) in FileTableView.toggleableColumns {
            guard let col = tv.tableColumn(withIdentifier: .init(id)) else { continue }
            let item = block(title) { [weak self] in
                self?.toggleColumnVisibility(id)
            }
            item.state = col.isHidden ? .off : .on
            menu.addItem(item)
        }
    }

    private func toggleColumnVisibility(_ id: String) {
        guard let tv = tableView,
              let col = tv.tableColumn(withIdentifier: .init(id)) else { return }
        col.isHidden.toggle()
        var visible = PreferencesService.shared.detailColumns
        visible.removeAll { $0 == id }
        if !col.isHidden { visible.append(id) }
        PreferencesService.shared.detailColumns = visible
    }

    // MARK: file menu

    private func buildFileMenu(_ menu: NSMenu, target: FileItem, urls: [URL]) {
        let nav = parent.nav

        menu.addItem(block("열기") { [weak self] in
            urls.forEach { url in
                if let item = self?.items.first(where: { $0.url == url }), item.isDirectory {
                    nav.navigate(to: url)
                } else {
                    FileSystemService.shared.openItem(url)
                }
            }
        })

        if target.isDirectory {
            menu.addItem(block("새 탭에서 열기") {
                NotificationCenter.default.post(name: .mfinderNewTab, object: target.url)
            })
            menu.addItem(block("새 창에서 열기") {
                FileSystemService.shared.openItem(target.url)
            })
            menu.addItem(block("폴더에서 새 터미널 열기") { [weak self] in
                self?.openTerminal(at: target.url)
            })
            menu.addItem(block("폴더에서 새 VS Code 열기") { [weak self] in
                self?.openInEditor(target.url, bundleId: "com.microsoft.VSCode")
            })
            // Add/remove this folder from the sidebar's 즐겨찾기 section.
            // Built-in presets (바탕 화면 등) remove by hiding, not unpinning.
            if PinnedFoldersService.shared.isInFavorites(target.url) {
                menu.addItem(block("즐겨찾기에서 제거") {
                    PinnedFoldersService.shared.removeFromFavorites(target.url)
                })
            } else {
                menu.addItem(block("즐겨찾기에 추가") {
                    PinnedFoldersService.shared.addToFavorites(target.url)
                })
            }
        } else {
            // 연결 프로그램 submenu
            let appsItem = NSMenuItem(title: "연결 프로그램", action: nil, keyEquivalent: "")
            let appsMenu = NSMenu()
            let appCandidates = NSWorkspace.shared.urlsForApplications(toOpen: target.url).prefix(8)
            for appURL in appCandidates {
                let name = appURL.deletingPathExtension().lastPathComponent
                appsMenu.addItem(block(name) { [weak self] in
                    self?.openWith(urls, app: appURL, errorLabel: "\(name)(으)로 열기 실패")
                })
            }
            appsMenu.addItem(.separator())
            appsMenu.addItem(block("App Store…") {
                if let appStore = URL(string: "macappstore://") {
                    NSWorkspace.shared.open(appStore)
                }
            })
            appsMenu.addItem(block("다른 앱 선택…") { [weak self] in
                self?.chooseAppAndOpen(urls)
            })
            appsItem.submenu = appsMenu
            menu.addItem(appsItem)

            menu.addItem(block("편집 (TextEdit)") { [weak self] in
                self?.editWithTextEdit(urls)
            })
        }

        menu.addItem(block("빠른 보기", key: " ") {
            QuickLookCoordinator.shared.toggle(urls: urls)
        })

        menu.addItem(block("정보 가져오기", key: "i") { [weak self] in
            self?.showProperties(target)
        })

        menu.addItem(.separator())

        menu.addItem(block("잘라내기", key: "x") {
            ClipboardService.shared.cut(urls)
        })
        menu.addItem(block("복사", key: "c") {
            ClipboardService.shared.copy(urls)
        })
        let fileMenuPaste = block("붙여넣기", key: "v") { [weak self] in
            self?.performPaste()
        }
        fileMenuPaste.isEnabled = ClipboardService.shared.hasContent
        menu.addItem(fileMenuPaste)
        menu.addItem(block("바로 가기 만들기") { [weak self] in
            self?.createAliases(urls)
        })

        let copyAdv = NSMenuItem(title: "복사: 추가 옵션", action: nil, keyEquivalent: "")
        let copyMenu = NSMenu()
        copyMenu.addItem(block("이름만 복사") { [weak self] in
            self?.copyToPasteboard(urls.map(\.lastPathComponent).joined(separator: "\n"))
        })
        copyMenu.addItem(block("전체 경로 복사") { [weak self] in
            self?.copyToPasteboard(urls.map(\.path).joined(separator: "\n"))
        })
        copyMenu.addItem(block("file:// URL 복사") { [weak self] in
            self?.copyToPasteboard(urls.map(\.absoluteString).joined(separator: "\n"))
        })
        copyMenu.addItem(block("UNIX 경로 (쉘 이스케이프) 복사") { [weak self] in
            let escaped = urls.map { "'\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
                              .joined(separator: " ")
            self?.copyToPasteboard(escaped)
        })
        copyAdv.submenu = copyMenu
        menu.addItem(copyAdv)

        // 새로 만들기 (creates inside the current folder, matching the empty-area menu).
        let newItem = NSMenuItem(title: "새로 만들기", action: nil, keyEquivalent: "")
        let newMenu = NSMenu()
        for (idx, tpl) in newItemTemplates.enumerated() {
            if idx == 1 { newMenu.addItem(.separator()) }
            if let filename = tpl.filename {
                newMenu.addItem(block(tpl.label) { [weak self] in self?.createNewFile(name: filename) })
            } else {
                newMenu.addItem(block(tpl.label) { [weak self] in self?.createNewFolder() })
            }
        }
        newItem.submenu = newMenu
        menu.addItem(newItem)

        menu.addItem(.separator())

        menu.addItem(block("이름 바꾸기") { [weak self] in
            guard let self = self,
                  let row = self.rowIndex(of: target.url)
            else { return }
            // Defer one tick so NSMenu has fully dismissed and the table view
            // is back in the responder chain before editColumn fires.
            DispatchQueue.main.async {
                self.startInlineRename(at: row)
            }
        })
        if urls.count > 1 {
            menu.addItem(block("일괄 이름 바꾸기 (\(urls.count)개)…") { [weak self] in
                guard let self else { return }
                promptBatchRename(urls, nav: self.parent.nav)
            })
        }
        menu.addItem(block("휴지통으로 이동") { [weak self] in
            self?.moveToTrash(urls)
        })
        menu.addItem(block("영구 삭제") { [weak self] in
            self?.permanentDelete(urls)
        })

        menu.addItem(.separator())

        // 보내기
        let sendTo = NSMenuItem(title: "보내기", action: nil, keyEquivalent: "")
        let sendMenu = NSMenu()
        sendMenu.addItem(block("바탕 화면 (바로 가기)") { [weak self] in
            self?.sendToDesktopShortcut(urls)
        })
        sendMenu.addItem(block("다운로드 폴더") { [weak self] in
            self?.copyURLs(urls, to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
        })
        sendMenu.addItem(block("문서 폴더") { [weak self] in
            self?.copyURLs(urls, to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
        })
        if ArchiveService.shared.bandizipAppURL != nil {
            sendMenu.addItem(.separator())
            sendMenu.addItem(block("Bandizip") {
                try? ArchiveService.shared.openWithBandizip(urls)
            })
        }
        sendMenu.addItem(.separator())
        sendMenu.addItem(block("AirDrop") {
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        })
        sendMenu.addItem(block("메일 수신자") {
            NSSharingService(named: .composeEmail)?.perform(withItems: urls)
        })
        sendMenu.addItem(block("메시지") {
            NSSharingService(named: .composeMessage)?.perform(withItems: urls)
        })
        sendTo.submenu = sendMenu
        menu.addItem(sendTo)

        menu.addItem(.separator())

        // Bandizip submenu
        let banditem = NSMenuItem(title: "Bandizip", action: nil, keyEquivalent: "")
        let bandmenu = NSMenu()
        let formats = ArchiveFormat.allCases.filter { ArchiveService.shared.canCompress(to: $0) }
        for fmt in formats {
            let name = suggestedArchiveName(for: urls, ext: fmt.rawValue)
            bandmenu.addItem(block("\"\(name)\"(으)로 압축") { [weak self] in
                self?.compress(urls: urls, format: fmt)
            })
        }
        if urls.count == 1, ArchiveService.shared.isArchive(urls[0]) {
            bandmenu.addItem(.separator())
            let archive = urls[0]
            bandmenu.addItem(block("여기에 압축 풀기") { [weak self] in
                self?.extractHere(archive)
            })
            bandmenu.addItem(block("\"\(ArchiveService.shared.basename(ofArchive: archive))\" 폴더에 압축 풀기") { [weak self] in
                self?.extractToFolder(archive)
            })
            bandmenu.addItem(block("압축 풀 위치 선택…") { [weak self] in
                self?.extractToCustomFolder(archive)
            })
            bandmenu.addItem(.separator())
            bandmenu.addItem(block("미리 보기") {
                QuickLookCoordinator.shared.toggle(urls: [archive])
            })
            bandmenu.addItem(block("압축 파일 검사") { [weak self] in
                self?.testArchive(archive)
            })
            bandmenu.addItem(block("압축 파일 정보 보기") { [weak self] in
                self?.archiveInfo(archive)
            })
        }
        banditem.submenu = bandmenu
        menu.addItem(banditem)

        // Share
        let shareItem = NSMenuItem(title: "공유", action: nil, keyEquivalent: "")
        let shareMenu = NSMenu()
        shareMenu.addItem(block("AirDrop") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls) })
        shareMenu.addItem(block("메일") { NSSharingService(named: .composeEmail)?.perform(withItems: urls) })
        shareMenu.addItem(block("메시지") { NSSharingService(named: .composeMessage)?.perform(withItems: urls) })
        shareMenu.addItem(.separator())
        shareMenu.addItem(block("공유 시트 표시…") { [weak self] in
            self?.showSharingPicker(urls)
        })
        shareItem.submenu = shareMenu
        menu.addItem(shareItem)

        menu.addItem(block("태그…") { [weak self] in
            self?.promptTags(urls)
        })

        menu.addItem(.separator())

        menu.addItem(block("Finder에서 보기") {
            FileSystemService.shared.revealInFinder(target.url)
        })
        menu.addItem(block("속성") { [weak self] in
            self?.showProperties(target)
        })
    }

    // MARK: empty area menu

    private func buildEmptyMenu(_ menu: NSMenu) {
        let nav = parent.nav

        // View
        let viewItem = NSMenuItem(title: "보기", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu()
        for mode in ViewMode.allCases {
            let item = block(mode.rawValue) { nav.viewMode = mode }
            item.state = (nav.viewMode == mode) ? .on : .off
            viewMenu.addItem(item)
        }
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        // Sort
        let sortItem = NSMenuItem(title: "정렬 기준", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        for field in SortField.allCases {
            let it = block(field.rawValue) { [weak self] in
                let asc = nav.sortField == field ? nav.sortAscending : true
                self?.parent.nav.applySort(field: field, ascending: asc)
            }
            it.state = (nav.sortField == field) ? .on : .off
            sortMenu.addItem(it)
        }
        sortMenu.addItem(.separator())
        let asc = block("오름차순") { nav.applySortDirection(ascending: true) }
        asc.state = nav.sortAscending ? .on : .off
        sortMenu.addItem(asc)
        let desc = block("내림차순") { nav.applySortDirection(ascending: false) }
        desc.state = !nav.sortAscending ? .on : .off
        sortMenu.addItem(desc)
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)

        // Group
        let groupItem = NSMenuItem(title: "그룹화 기준", action: nil, keyEquivalent: "")
        let groupMenu = NSMenu()
        for field in GroupField.allCases {
            let it = block(field.rawValue) { nav.groupField = field }
            it.state = (nav.groupField == field) ? .on : .off
            groupMenu.addItem(it)
        }
        groupItem.submenu = groupMenu
        menu.addItem(groupItem)

        menu.addItem(block("새로 고침", key: "r") { nav.reload() })

        menu.addItem(.separator())

        let undoItem = block(UndoService.shared.undoMenuTitle, key: "z") {
            UndoService.shared.undo()
        }
        undoItem.isEnabled = UndoService.shared.canUndo
        menu.addItem(undoItem)

        menu.addItem(.separator())

        let paste = block("붙여넣기", key: "v") { [weak self] in
            self?.performPaste()
        }
        paste.isEnabled = ClipboardService.shared.hasContent
        menu.addItem(paste)

        let pasteShortcut = block("바로 가기 붙여넣기") { [weak self] in
            self?.pasteAsShortcut()
        }
        pasteShortcut.isEnabled = ClipboardService.shared.hasContent
        menu.addItem(pasteShortcut)

        menu.addItem(.separator())

        // 새로 만들기
        let newItem = NSMenuItem(title: "새로 만들기", action: nil, keyEquivalent: "")
        let newMenu = NSMenu()
        for (idx, tpl) in newItemTemplates.enumerated() {
            if idx == 1 { newMenu.addItem(.separator()) }
            if let filename = tpl.filename {
                newMenu.addItem(block(tpl.label) { [weak self] in self?.createNewFile(name: filename) })
            } else {
                newMenu.addItem(block(tpl.label) { [weak self] in self?.createNewFolder() })
            }
        }
        newItem.submenu = newMenu
        menu.addItem(newItem)

        // Bandizip on folder
        let bandItem = NSMenuItem(title: "Bandizip", action: nil, keyEquivalent: "")
        let bandMenu = NSMenu()
        for fmt in ArchiveFormat.allCases where ArchiveService.shared.canCompress(to: fmt) {
            bandMenu.addItem(block("이 폴더를 \(fmt.rawValue)로 압축") { [weak self] in
                self?.compressFolderItself(nav.currentURL, format: fmt)
            })
        }
        bandItem.submenu = bandMenu
        menu.addItem(bandItem)

        menu.addItem(.separator())

        menu.addItem(block("폴더에서 새 터미널 열기") { [weak self] in
            self?.openTerminal(at: nav.currentURL)
        })
        menu.addItem(block("현재 경로 복사") { [weak self] in
            self?.copyToPasteboard(nav.currentURL.path)
        })
        menu.addItem(block("Finder에서 열기") {
            FileSystemService.shared.revealInFinder(nav.currentURL)
        })

        menu.addItem(.separator())

        menu.addItem(block("속성") { [weak self] in
            self?.showFolderProperties(nav.currentURL)
        })
    }

    // MARK: - Menu action dispatch (representedObject pattern)
    // Each menu item targets the Coordinator and carries its closure via
    // representedObject. This is the conventional AppKit dispatch pattern and
    // avoids subclassing NSMenuItem.

    private func block(_ title: String, key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(invokeMenuAction(_:)),
                              keyEquivalent: key)
        item.target = self
        item.representedObject = ActionBox(action: action)
        return item
    }

    @objc fileprivate func invokeMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? ActionBox)?.action()
    }

    // MARK: - Action helpers (mirror FileListView methods)

    private func suggestedArchiveName(for urls: [URL], ext: String) -> String {
        let folderName = parent.nav.currentURL.lastPathComponent
        let base: String
        if urls.count == 1 {
            base = urls[0].deletingPathExtension().lastPathComponent
        } else if !folderName.isEmpty {
            base = folderName
        } else {
            base = "압축"
        }
        return "\(base).\(ext)"
    }

    private func compress(urls: [URL], format: ArchiveFormat) {
        let name = suggestedArchiveName(for: urls, ext: format.rawValue)
        let uniqueName = unique(name, in: parent.nav.currentURL).lastPathComponent
        do {
            try ArchiveService.shared.compress(urls, into: parent.nav.currentURL,
                                               archiveName: uniqueName, format: format)
            parent.nav.reload()
        } catch {
            alertError("압축 실패", message: error.localizedDescription)
        }
    }

    private func compressFolderItself(_ folder: URL, format: ArchiveFormat) {
        let parentDir = folder.deletingLastPathComponent()
        let name = "\(folder.lastPathComponent).\(format.rawValue)"
        let uniqueName = unique(name, in: parentDir).lastPathComponent
        do {
            try ArchiveService.shared.compress([folder], into: parentDir,
                                               archiveName: uniqueName, format: format)
            parent.nav.reload()
        } catch {
            alertError("압축 실패", message: error.localizedDescription)
        }
    }

    private func extractHere(_ url: URL) {
        do {
            try ArchiveService.shared.extractHere(url)
            parent.nav.reload()
        } catch { alertError("압축 풀기 실패", message: error.localizedDescription) }
    }

    private func extractToFolder(_ url: URL) {
        do {
            _ = try ArchiveService.shared.extractIntoFolder(url)
            parent.nav.reload()
        } catch { alertError("압축 풀기 실패", message: error.localizedDescription) }
    }

    private func extractToCustomFolder(_ url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        if panel.runModal() == .OK, let dst = panel.url {
            do {
                try ArchiveService.shared.extract(url, into: dst)
                parent.nav.reload()
            } catch { alertError("압축 풀기 실패", message: error.localizedDescription) }
        }
    }

    private func testArchive(_ url: URL) {
        do {
            let result = try ArchiveService.shared.testArchive(url)
            longAlert(title: "압축 파일 검사", text: result.isEmpty ? "이상 없음." : result)
        } catch { alertError("검사 실패", message: error.localizedDescription) }
    }

    private func archiveInfo(_ url: URL) {
        do {
            let result = try ArchiveService.shared.archiveInfo(url)
            longAlert(title: "압축 파일 정보 — \(url.lastPathComponent)", text: result)
        } catch { alertError("정보 표시 실패", message: error.localizedDescription) }
    }

    /// Single dispatch point for "open files with this app" — surfaces async
    /// errors via NSAlert on the main queue so silent failures stop happening.
    private func openWith(_ urls: [URL], app: URL, errorLabel: String) {
        NSWorkspace.shared.open(urls, withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.alertError(errorLabel, message: error.localizedDescription)
                }
            }
        }
    }

    private func chooseAppAndOpen(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let app = panel.url {
            openWith(urls, app: app, errorLabel: "앱으로 열기 실패")
        }
    }

    private func openTerminal(at url: URL) {
        // Try Terminal.app, then iTerm
        let candidates = [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/iTerm.app"
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            alertError("터미널 실행 실패", message: "Terminal.app 또는 iTerm.app을 찾을 수 없습니다.")
            return
        }
        openWith([url], app: URL(fileURLWithPath: path), errorLabel: "터미널 열기 실패")
    }

    private func sendToDesktopShortcut(_ urls: [URL]) {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        var firstErr: Error?
        var created: [URL] = []
        for src in urls {
            let dst = unique("\(src.lastPathComponent) 바로 가기", in: desktop)
            do {
                try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
                created.append(dst)
            } catch {
                if firstErr == nil { firstErr = error }
            }
        }
        if let err = firstErr, created.isEmpty {
            alertError("바로 가기 만들기 실패", message: err.localizedDescription)
        }
    }

    private func createAliases(_ urls: [URL]) {
        var created: [URL] = []
        var firstErr: Error?
        for src in urls {
            let dst = unique("\(src.lastPathComponent) 바로 가기", in: parent.nav.currentURL)
            do {
                try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
                created.append(dst)
            } catch {
                if firstErr == nil { firstErr = error }
            }
        }
        if !created.isEmpty {
            UndoService.shared.register(.create(urls: created), label: "바로 가기 만들기")
            parent.nav.reload(thenSelect: Set(created))
        }
        if let err = firstErr, created.isEmpty {
            alertError("바로 가기 만들기 실패", message: err.localizedDescription)
        }
    }

    /// Used by 보내기 → 다운로드/문서 폴더. Reload only if dst is current dir.
    private func copyURLs(_ urls: [URL], to dir: URL) {
        var firstErr: Error?
        for src in urls {
            let dst = unique(src.lastPathComponent, in: dir)
            do {
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                if firstErr == nil { firstErr = error }
            }
        }
        if dir.standardizedFileURL == parent.nav.currentURL.standardizedFileURL {
            parent.nav.reload()
        }
        if let err = firstErr {
            alertError("복사 실패", message: err.localizedDescription)
        }
    }

    private func moveToTrash(_ urls: [URL]) {
        var firstErr: Error?
        var trashed: [URL] = []
        for url in urls {
            do {
                try FileSystemService.shared.moveToTrash(url)
                trashed.append(url)
            } catch {
                if firstErr == nil { firstErr = error }
            }
        }
        UndoService.shared.register(.trash(originals: trashed), label: "휴지통으로 이동")
        parent.nav.selectedItems.subtract(trashed)
        parent.nav.reload()
        if let err = firstErr {
            alertError("휴지통 이동 실패", message: err.localizedDescription)
        }
    }

    private func pasteAsShortcut() {
        let pb = NSPasteboard.general
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
        guard !urls.isEmpty else {
            alertError("바로 가기 붙여넣기 실패", message: "클립보드에 파일/폴더가 없습니다.")
            return
        }
        createAliases(urls)
    }

    private func editWithTextEdit(_ urls: [URL]) {
        // Prefer the bundle-ID lookup so this works regardless of which volume hosts /System.
        let textEdit: URL?
        if let viaBundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            textEdit = viaBundle
        } else {
            let candidates = [
                "/System/Applications/TextEdit.app",
                "/Applications/TextEdit.app"
            ]
            textEdit = candidates.lazy
                .map { URL(fileURLWithPath: $0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let app = textEdit else {
            alertError("편집 실패", message: "TextEdit을 찾을 수 없습니다.")
            return
        }
        openWith(urls, app: app, errorLabel: "TextEdit으로 열기 실패")
    }

    private func openInEditor(_ url: URL, bundleId: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            alertError("앱을 찾을 수 없습니다", message: "\(bundleId) 가 설치되지 않았습니다.")
            return
        }
        openWith([url], app: appURL, errorLabel: "에디터로 열기 실패")
    }

    private func promptTags(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "태그"
        alert.informativeText = "쉼표로 구분하여 입력하세요 (예: 작업, 중요)."
        alert.addButton(withTitle: "적용")
        alert.addButton(withTitle: "취소")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let existing = (try? (urls[0] as NSURL).resourceValues(forKeys: [.tagNamesKey])[.tagNamesKey] as? [String]) ?? []
        tf.stringValue = existing.joined(separator: ", ")
        alert.accessoryView = tf
        if alert.runModal() == .alertFirstButtonReturn {
            let tags = tf.stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var firstErr: Error?
            for url in urls {
                do {
                    try (url as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
                } catch {
                    if firstErr == nil { firstErr = error }
                }
            }
            parent.nav.reload()
            if let err = firstErr {
                alertError("태그 적용 실패", message: err.localizedDescription)
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    private func createNewFolder() {
        let url = unique("새 폴더", in: parent.nav.currentURL)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            UndoService.shared.register(.create(urls: [url]), label: "새로 만들기")
            parent.nav.reload(thenSelect: [url])
        } catch {
            alertError("폴더 만들기 실패", message: error.localizedDescription)
        }
    }

    private func createNewFile(name: String) {
        let url = unique(name, in: parent.nav.currentURL)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            alertError("파일 만들기 실패", message: "\(url.path) 에 파일을 만들 수 없습니다.")
            return
        }
        UndoService.shared.register(.create(urls: [url]), label: "새로 만들기")
        parent.nav.reload(thenSelect: [url])
    }

    private func showSharingPicker(_ urls: [URL]) {
        let picker = NSSharingServicePicker(items: urls)
        guard let window = NSApp.keyWindow,
              let view = window.contentView else { return }
        let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    private func permanentDelete(_ urls: [URL]) {
        let alert = NSAlert()
        alert.messageText = "영구 삭제하시겠습니까?"
        alert.informativeText = "이 작업은 되돌릴 수 없습니다. \(urls.count)개 항목이 영구적으로 삭제됩니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            var firstErr: Error?
            var deleted: [URL] = []
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                    deleted.append(url)
                } catch {
                    if firstErr == nil { firstErr = error }
                }
            }
            parent.nav.selectedItems.subtract(deleted)
            parent.nav.reload()
            if let err = firstErr {
                alertError("영구 삭제 실패", message: err.localizedDescription)
            }
        }
    }

    private func promptRename(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "이름 바꾸기"
        alert.informativeText = "새 이름을 입력하세요."
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.stringValue = url.lastPathComponent
        alert.accessoryView = tf
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != url.lastPathComponent else { return }
            let dst = url.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: url, to: dst)
                parent.nav.reload(thenSelect: [dst])
            } catch {
                alertError("이름 바꾸기 실패", message: error.localizedDescription)
            }
        }
    }

    private func showProperties(_ item: FileItem) {
        let alert = NSAlert()
        alert.messageText = item.name
        var lines: [String] = []
        lines.append("종류: \(item.typeDescription)")
        lines.append("경로: \(item.url.path)")
        if !item.isDirectory { lines.append("크기: \(item.sizeString)") }
        lines.append("수정한 날짜: \(item.modificationString)")
        alert.informativeText = lines.joined(separator: "\n")
        alert.icon = item.icon
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "Finder에서 보기")
        if alert.runModal() == .alertSecondButtonReturn {
            FileSystemService.shared.revealInFinder(item.url)
        }
    }

    private func showFolderProperties(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        var lines: [String] = []
        lines.append("종류: 폴더")
        lines.append("경로: \(url.path)")
        if let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let m = vals.contentModificationDate { lines.append("수정한 날짜: \(f.string(from: m))") }
            if let c = vals.creationDate { lines.append("만든 날짜: \(f.string(from: c))") }
        }
        let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
        lines.append("항목 수: \(count)")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func alertError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func longAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "확인")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        tv.isEditable = false
        tv.string = text
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = tv
        alert.accessoryView = scroll
        alert.runModal()
    }

    private func unique(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let url = URL(fileURLWithPath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            i += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

// MARK: - Closure wrapper attached to NSMenuItem.representedObject

final class ActionBox: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
}
