import SwiftUI
import AppKit

/// Column view (열 보기): Finder-style Miller columns. Each column lists a
/// folder's contents; selecting a folder opens the next column to its right,
/// and selecting a file shows a Quick Look preview in the trailing column.
struct ColumnsBrowserView: View {
    @EnvironmentObject var nav: NavigationState
    @ObservedObject private var themes = ThemeService.shared

    /// Folder URLs, left to right. columns[0] is the current folder.
    @State private var columns: [URL] = []
    /// Selected child per column folder.
    @State private var selection: [URL: URL] = [:]
    /// Lazily-loaded children per folder.
    @State private var cache: [URL: [FileItem]] = [:]

    private let columnWidth: CGFloat = 240

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element) { idx, folder in
                        column(folder, index: idx)
                            .frame(width: columnWidth)
                            .id(folder)
                        Divider()
                    }
                    if let leaf = leafPreviewURL {
                        QuickLookPreview(url: leaf)
                            .frame(width: columnWidth * 1.4)
                            .id("leaf")
                            .padding(8)
                    }
                }
            }
            .onChange(of: columns) { cols in
                if let last = cols.last { withAnimation { proxy.scrollTo(last, anchor: .trailing) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themes.theme.contentBackground.color)
        .onAppear { reset(to: nav.currentURL) }
        .onChange(of: nav.currentURL) { url in
            // Only reset when the navigation moved outside the current column path
            // (e.g. address bar / sidebar) — selecting within columns keeps state.
            if !columns.contains(url) { reset(to: url) }
        }
    }

    /// A file selected in the last column gets a preview column.
    private var leafPreviewURL: URL? {
        guard let lastFolder = columns.last, let sel = selection[lastFolder] else { return nil }
        let isDir = cache[lastFolder]?.first { $0.url == sel }?.isDirectory ?? false
        return isDir ? nil : sel
    }

    private func column(_ folder: URL, index: Int) -> some View {
        let items = children(of: folder)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    let isSel = selection[folder] == item.url
                    HStack(spacing: 6) {
                        IconView(item: item, size: 16)
                        Text(item.displayName)
                            .font(.system(size: themes.fontSize))
                            .foregroundColor(isSel ? .white : themes.theme.text.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if item.isDirectory {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(isSel ? .white : themes.theme.secondaryText.color)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSel ? themes.theme.selection.color : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if item.isDirectory { nav.navigate(to: item.url) }
                        else { NSWorkspace.shared.open(item.url) }
                    }
                    .onTapGesture { select(item, inColumn: index, folder: folder) }
                }
            }
            .padding(.vertical, 2)
        }
        .background(themes.theme.contentBackground.color)
    }

    private func select(_ item: FileItem, inColumn index: Int, folder: URL) {
        selection[folder] = item.url
        nav.selectedItems = [item.url]
        AppFocus.area = .fileList
        // Truncate columns to this one, then append the folder if it is one.
        var cols = Array(columns.prefix(index + 1))
        if item.isDirectory { cols.append(item.url) }
        columns = cols
    }

    private func children(of folder: URL) -> [FileItem] {
        if let c = cache[folder] { return c }
        let items = (try? FileSystemService.shared.listContents(of: folder, showHidden: nav.showHidden)) ?? []
        let sorted = items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        DispatchQueue.main.async { cache[folder] = sorted }
        return sorted
    }

    private func reset(to url: URL) {
        columns = [url]
        selection = [:]
        cache = [:]
    }
}
