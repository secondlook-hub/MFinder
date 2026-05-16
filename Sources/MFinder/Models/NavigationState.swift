import Foundation
import SwiftUI
import Combine
import AppKit

enum ViewMode: String, CaseIterable, Identifiable {
    case extraLargeIcons = "아주 큰 아이콘"
    case largeIcons      = "큰 아이콘"
    case mediumIcons     = "보통 아이콘"
    case smallIcons      = "작은 아이콘"
    case list            = "목록"
    case details         = "자세히"
    case tiles           = "나란히 보기"
    case content         = "내용"

    var id: String { rawValue }

    var iconSize: CGFloat {
        switch self {
        case .extraLargeIcons: return 96
        case .largeIcons:      return 72
        case .mediumIcons:     return 48
        case .smallIcons:      return 16
        case .list:            return 16
        case .details:         return 16
        case .tiles:           return 48
        case .content:         return 32
        }
    }

    var symbol: String {
        switch self {
        case .extraLargeIcons, .largeIcons, .mediumIcons: return "square.grid.2x2"
        case .smallIcons: return "square.grid.3x3"
        case .list:       return "list.bullet"
        case .details:    return "list.dash"
        case .tiles:      return "rectangle.grid.2x2"
        case .content:    return "doc.text.below.ecg"
        }
    }
}

enum SortField: String, CaseIterable {
    case name = "이름"
    case modified = "수정한 날짜"
    case type = "유형"
    case size = "크기"
}

/// Parsed search query: separates include tokens, exclude (`-foo`) tokens, and
/// quoted phrases into a structured form. `"hello world" -draft swift func`
/// becomes includes=["hello world", "swift", "func"], excludes=["draft"].
struct SearchTokens: Equatable {
    var includes: [String] = []
    var excludes: [String] = []

    static let empty = SearchTokens()

    var isEmpty: Bool { includes.isEmpty && excludes.isEmpty }
    var primary: String { includes.first ?? "" }
    var cacheKey: String {
        let inc = includes.map { $0.lowercased() }.sorted().joined(separator: ",")
        let exc = excludes.map { $0.lowercased() }.sorted().joined(separator: ",")
        return "+[\(inc)]-[\(exc)]"
    }

    static func parse(_ input: String) -> SearchTokens {
        var tokens = SearchTokens()
        var current = ""
        var inQuotes = false
        var nextIsExclude = false

        func commit() {
            guard !current.isEmpty else { return }
            if nextIsExclude { tokens.excludes.append(current) }
            else             { tokens.includes.append(current) }
            current = ""
            nextIsExclude = false
        }

        for ch in input {
            if ch == "\"" {
                if inQuotes {
                    commit()
                    inQuotes = false
                } else {
                    // Starting a quote also commits any in-progress token.
                    commit()
                    inQuotes = true
                }
            } else if inQuotes {
                current.append(ch)
            } else if ch == " " || ch == "\t" {
                commit()
            } else if ch == "-" && current.isEmpty && !nextIsExclude {
                nextIsExclude = true
            } else {
                current.append(ch)
            }
        }
        commit()
        return tokens
    }
}

enum FocusArea {
    case fileList
    case sidebar
}

/// Process-wide tracker of which pane the user most recently interacted with.
/// Read by the AppDelegate's key monitor (to decide whether to intercept
/// Cmd+X/C/V) and by the per-tab notification handlers (to decide whether to
/// act). Single global because the key monitor isn't tab-aware — the most
/// recent interaction wins, which is also what users intuitively expect.
@MainActor
enum AppFocus {
    static var area: FocusArea = .fileList
}

@MainActor
final class NavigationState: ObservableObject {
    @Published var currentURL: URL
    @Published var items: [FileItem] = [] {
        didSet { recomputeFiltered() }
    }
    @Published var selectedItems: Set<URL> = []
    @Published var viewMode: ViewMode = .details {
        didSet { PreferencesService.shared.viewMode = viewMode }
    }
    @Published var sortField: SortField = .name {
        didSet { PreferencesService.shared.sortField = sortField }
    }
    @Published var sortAscending: Bool = true {
        didSet { PreferencesService.shared.sortAscending = sortAscending }
    }
    @Published var showHidden: Bool = false {
        didSet {
            PreferencesService.shared.showHidden = showHidden
            reload()
        }
    }
    @Published var searchText: String = "" {
        didSet {
            if oldValue != searchText {
                searchTokens = SearchTokens.parse(searchText)
                handleSearchTextChange()
            }
        }
    }
    /// Parsed view of `searchText`. Re-derived in `searchText.didSet` and consumed
    /// by both the Spotlight predicate and the inline snippet highlighter.
    @Published private(set) var searchTokens: SearchTokens = .empty
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false
    @Published private(set) var filteredItems: [FileItem] = []
    @Published var renamingURL: URL? = nil
    /// URLs currently multi-selected in the sidebar tree. Published by the
    /// SidebarOutlineView coordinator so notification-driven keyboard
    /// shortcuts (Cmd+C / Cmd+X / ⌘⌫ when the sidebar has focus) can act on
    /// the full selection. Empty when nothing is selected; falls back to
    /// `[currentURL]` at the call site.
    @Published var sidebarSelectionURLs: [URL] = []
    @Published private(set) var dataVersion: Int = 0
    /// True while a Spotlight query is in progress (used by status bar / address bar).
    @Published private(set) var isSearching: Bool = false
    /// Cumulative results from the running Spotlight search. Empty when not searching.
    @Published private(set) var searchResults: [FileItem] = []

    let tree: FolderTreeStore

    private var history: [URL] = []
    private var forwardStack: [URL] = []
    private var loadGeneration: Int = 0
    /// Selection to apply on the *next successful* reload, surviving any
    /// intervening reload that gets cancelled by a later one (e.g. an FSEvent
    /// reload firing right after a paste-triggered reload(thenSelect:)).
    private var pendingSelection: Set<URL>?

    // Search infrastructure
    private var metadataQuery: NSMetadataQuery?
    private var queryObservers: [NSObjectProtocol] = []

    // External file-system change watcher. Watches the active folder plus
    // every currently-expanded sidebar tree node so changes made by Finder,
    // a download, or `mv` from a shell are reflected immediately.
    private var fsWatcher: FileSystemWatcher!
    private var watchCancellables: [AnyCancellable] = []
    private var watchUpdateTask: DispatchWorkItem?

    // Tracks folders we've already prompted for permission on, to avoid
    // re-prompting every time the user revisits an inaccessible folder
    // (e.g. OneDrive / Google Drive / Dropbox under ~/Library/CloudStorage).
    private var permissionAlertedURLs: Set<URL> = []

    init(startingURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = startingURL
        self.tree = FolderTreeStore()
        // Load persisted prefs *before* the first reload so the listing
        // honors showHidden. Setting these inside init doesn't fire didSet.
        self.showHidden    = PreferencesService.shared.showHidden
        self.viewMode      = PreferencesService.shared.viewMode
        self.sortField     = PreferencesService.shared.sortField
        self.sortAscending = PreferencesService.shared.sortAscending

        // FSEvents watcher — installed after `self` is fully constructed.
        self.fsWatcher = FileSystemWatcher { [weak self] changedPaths in
            self?.handleFileSystemChanges(changedPaths)
        }

        reload()
        self.tree.ensureVisible(startingURL)
        installWatchSubscriptions()
    }

    deinit {
        // Manual cleanup; Notification observers are class-instance bound.
        metadataQuery?.stop()
        for o in queryObservers {
            NotificationCenter.default.removeObserver(o)
        }
    }

    private func recomputeFiltered() {
        if searchText.isEmpty {
            filteredItems = items
        } else {
            // Local filename pre-pass: file matches if its name contains all
            // include tokens (any of them as substring) AND none of the excludes.
            let tokens = searchTokens
            let localMatches: [FileItem] = items.filter { item in
                let lower = item.name.lowercased()
                for inc in tokens.includes where !lower.contains(inc.lowercased()) { return false }
                for exc in tokens.excludes where  lower.contains(exc.lowercased()) { return false }
                return !tokens.includes.isEmpty
            }
            var seen = Set<URL>()
            var combined: [FileItem] = []
            for item in localMatches {
                let s = item.url.standardizedFileURL
                if seen.insert(s).inserted { combined.append(item) }
            }
            for item in searchResults {
                let s = item.url.standardizedFileURL
                if seen.insert(s).inserted { combined.append(item) }
            }
            filteredItems = combined
        }
        dataVersion &+= 1
    }

    // MARK: - Navigation

    func navigate(to url: URL) {
        let target = url.standardizedFileURL
        guard target != currentURL else { return }
        if !searchText.isEmpty { searchText = "" }  // cancels search
        history.append(currentURL)
        forwardStack.removeAll()
        currentURL = target
        selectedItems.removeAll()
        pendingSelection = nil    // navigating away invalidates any in-flight selection
        reload()
        // Reveal the destination in the sidebar tree synchronously — symlink /
        // alias jumps land outside the previously-expanded subtree, so we need
        // to expand ancestors so the new row is visible and highlighted.
        tree.ensureVisible(target)
    }

    func goBack() {
        guard let prev = history.popLast() else { return }
        if !searchText.isEmpty { searchText = "" }
        forwardStack.append(currentURL)
        currentURL = prev
        selectedItems.removeAll()
        pendingSelection = nil
        reload()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if !searchText.isEmpty { searchText = "" }
        history.append(currentURL)
        currentURL = next
        selectedItems.removeAll()
        pendingSelection = nil
        reload()
    }

    func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        if parent.path != currentURL.path {
            navigate(to: parent)
        }
    }

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool {
        currentURL.deletingLastPathComponent().path != currentURL.path
    }

    func reload(thenSelect newSelection: Set<URL>? = nil) {
        loadGeneration += 1
        let myGen = loadGeneration
        let url = currentURL
        let showHidden = self.showHidden
        // Record the desired selection outside the async closure so it
        // survives a follow-up reload (e.g. one triggered by an FSEvent
        // hitting the destination folder right after a paste) cancelling
        // *this* reload's completion via the loadGeneration guard.
        if let sel = newSelection {
            pendingSelection = sel
        }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result: Result<[FileItem], Error>
            do {
                let items = try FileSystemService.shared.listContents(of: url, showHidden: showHidden)
                result = .success(items)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                guard myGen == self.loadGeneration else { return }
                self.isLoading = false
                switch result {
                case .success(let raw):
                    self.items = self.sorted(raw)
                    self.errorMessage = nil
                    if let target = self.pendingSelection {
                        let standardized = Set(target.map { $0.standardizedFileURL })
                        let present = self.items.filter { standardized.contains($0.url.standardizedFileURL) }
                        if !present.isEmpty {
                            self.selectedItems = Set(present.map { $0.url })
                            // Only clear once the target items actually
                            // showed up — otherwise a follow-up reload
                            // (FSEvent batching, etc.) can still apply it.
                            self.pendingSelection = nil
                        }
                    }
                case .failure(let err):
                    self.items = []
                    if Self.isPermissionError(err) {
                        self.errorMessage = "이 폴더에 접근 권한이 없습니다."
                        self.presentPermissionAlert(for: url)
                    } else {
                        self.errorMessage = err.localizedDescription
                    }
                }
            }
        }
    }

    // MARK: - Permission error UX

    /// Cloud-storage folders (OneDrive / Google Drive / Dropbox under
    /// `~/Library/CloudStorage/…`) and other TCC-protected locations
    /// return a permission error until the user grants Full Disk Access
    /// (or per-folder access) to MFinder in System Settings. We detect
    /// the error here so the alert can guide them to the right pane.
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            // NSFileReadNoPermissionError = 257
            if ns.code == 257 { return true }
        }
        if ns.domain == NSPOSIXErrorDomain {
            // 1 = EPERM (Operation not permitted), 13 = EACCES (Permission denied)
            if ns.code == 1 || ns.code == 13 { return true }
        }
        return false
    }

    private func presentPermissionAlert(for url: URL) {
        let std = url.standardizedFileURL
        guard !permissionAlertedURLs.contains(std) else { return }
        permissionAlertedURLs.insert(std)

        let alert = NSAlert()
        alert.messageText = "이 폴더에 접근할 수 없습니다"
        alert.informativeText = """
            \(std.lastPathComponent) 폴더의 내용을 읽으려면 macOS의 추가 권한이 필요합니다.

            OneDrive, Google Drive, Dropbox 같은 클라우드 동기화 폴더와 일부 시스템 폴더는 보안 정책으로 보호받고 있어서 앱마다 별도 권한이 요구됩니다.

            시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한 에서 MFinder를 추가하거나 켜고, 앱을 다시 시작해 주세요.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "확인")
        if alert.runModal() == .alertFirstButtonReturn {
            // x-apple.systempreferences URL → Privacy & Security → Full Disk Access
            if let prefURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(prefURL)
            }
        }
    }

    // MARK: - Sort

    func setSort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = true
        }
        items = sorted(items)
    }

    func applySort(field: SortField, ascending: Bool) {
        sortField = field
        sortAscending = ascending
        items = sorted(items)
    }

    func applySortDirection(ascending: Bool) {
        sortAscending = ascending
        items = sorted(items)
    }

    private func sorted(_ source: [FileItem]) -> [FileItem] {
        source.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let cmp: ComparisonResult
            switch sortField {
            case .name:
                cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case .modified:
                cmp = lhs.modificationDate.compare(rhs.modificationDate)
            case .type:
                cmp = lhs.typeDescription.localizedCaseInsensitiveCompare(rhs.typeDescription)
            case .size:
                cmp = lhs.size < rhs.size ? .orderedAscending
                    : lhs.size > rhs.size ? .orderedDescending : .orderedSame
            }
            if cmp == .orderedSame {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return sortAscending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }

    var pathComponents: [(name: String, url: URL)] {
        var comps: [(String, URL)] = []
        var url = currentURL
        while url.path != "/" {
            let name = url.lastPathComponent
            comps.insert((name, url), at: 0)
            url = url.deletingLastPathComponent()
        }
        comps.insert(("내 PC", URL(fileURLWithPath: "/")), at: 0)
        return comps
    }

    // MARK: - Search (Spotlight / NSMetadataQuery)

    private func handleSearchTextChange() {
        stopSearch()
        if searchTokens.isEmpty {
            searchResults = []
            recomputeFiltered()
        } else {
            startSearch(tokens: searchTokens, scope: currentURL)
            recomputeFiltered()
        }
    }

    private func startSearch(tokens: SearchTokens, scope: URL) {
        isSearching = true
        searchResults = []

        let query = NSMetadataQuery()
        // Restrict the search to current folder and its subtree.
        query.searchScopes = [scope]

        // Compose per-token "filename OR fs-name OR content" sub-predicates
        // and AND them all together; wrap excludes in NOT.
        let perTokenFormat = """
            (kMDItemDisplayName CONTAINS[cd] %@) \
            OR (kMDItemFSName CONTAINS[cd] %@) \
            OR (kMDItemTextContent CONTAINS[cd] %@)
            """
        var subs: [NSPredicate] = tokens.includes.map { token in
            NSPredicate(format: perTokenFormat, token, token, token)
        }
        for token in tokens.excludes {
            let p = NSPredicate(format: perTokenFormat, token, token, token)
            subs.append(NSCompoundPredicate(notPredicateWithSubpredicate: p))
        }
        query.predicate = subs.count == 1
            ? subs[0]
            : NSCompoundPredicate(andPredicateWithSubpredicates: subs)
        query.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)
        ]
        query.notificationBatchingInterval = 0.3

        let center = NotificationCenter.default
        let onUpdate: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySearchResults()
            }
        }
        let onFinish: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySearchResults()
                self?.isSearching = false
            }
        }
        queryObservers.append(center.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: query,
            queue: .main, using: onUpdate))
        queryObservers.append(center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query,
            queue: .main, using: onFinish))

        metadataQuery = query
        query.start()
    }

    private func stopSearch() {
        metadataQuery?.stop()
        metadataQuery = nil
        for o in queryObservers { NotificationCenter.default.removeObserver(o) }
        queryObservers = []
        isSearching = false
    }

    // MARK: - External-change watcher

    private func installWatchSubscriptions() {
        // currentURL changes → re-aim the watcher
        $currentURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleWatchUpdate() }
            .store(in: &watchCancellables)

        // expanded folders set changes → re-aim the watcher
        tree.$expandedURLs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleWatchUpdate() }
            .store(in: &watchCancellables)

        // Initial watch.
        updateWatchSet()
    }

    /// Coalesces rapid bursts of watch-set changes (e.g., expanding several
    /// tree nodes in quick succession) into a single FSEvents stream rebuild.
    private func scheduleWatchUpdate() {
        watchUpdateTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.updateWatchSet()
        }
        watchUpdateTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
    }

    private func updateWatchSet() {
        var urls: [URL] = [currentURL.standardizedFileURL]
        for u in tree.expandedURLs {
            let std = u.standardizedFileURL
            // Skip "/" — too broad and may be blocked by macOS privacy controls.
            if std.path == "/" { continue }
            urls.append(std)
        }
        fsWatcher.setWatch(urls)
    }

    /// FSEvents reported activity inside one of our watched folders. Refresh
    /// the file list if it's our current folder and the affected tree branch
    /// if it's expanded.
    private func handleFileSystemChanges(_ changedPaths: Set<URL>) {
        // Skip refreshes while an inline rename is active — reloading children
        // triggers @Published mutations on the tree store, which invalidates
        // every FolderTreeRow and tears down the active RenameTextField.
        // The user will see fresh state once they commit/cancel the rename.
        if renamingURL != nil { return }
        let curStd = currentURL.standardizedFileURL
        for url in changedPaths {
            let std = url.standardizedFileURL
            if std == curStd {
                // Don't clobber an in-flight search.
                if searchText.isEmpty {
                    reload()
                }
            }
            if tree.isExpanded(std) {
                tree.reloadChildren(of: std)
            }
        }
    }

    private func applySearchResults() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var results: [FileItem] = []
        let count = query.resultCount
        // Cap to avoid huge UI work on broad searches.
        let cap = min(count, 5000)
        for i in 0..<cap {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            // Exclude the search root itself if Spotlight returns it.
            if url.standardizedFileURL == currentURL.standardizedFileURL { continue }
            if let fi = FileSystemService.shared.fileItem(from: url) {
                results.append(fi)
            }
        }
        searchResults = results
        recomputeFiltered()
    }
}
