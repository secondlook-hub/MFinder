import SwiftUI
import AppKit

/// Win11-style icon command bar: a single horizontal row of compact icon
/// buttons. No tabs, no panels, no nested groups.
struct CommandBar: View {
    @EnvironmentObject var nav: NavigationState
    @ObservedObject private var clipboard = ClipboardService.shared
    @State private var showPreview = false

    var body: some View {
        HStack(spacing: 4) {
            // "새로 만들기" — icon + text + chevron in a single combined button
            newButton

            verticalDivider

            // Action icons (no text labels)
            iconButton(symbol: "scissors",                help: "잘라내기 (⌘X)",
                       disabled: nav.selectedItems.isEmpty) {
                ClipboardService.shared.cut(orderedSelection())
            }
            iconButton(symbol: "doc.on.doc",              help: "복사 (⌘C)",
                       disabled: nav.selectedItems.isEmpty) {
                ClipboardService.shared.copy(orderedSelection())
            }
            iconButton(symbol: "doc.on.clipboard",        help: "붙여넣기 (⌘V)",
                       disabled: !clipboard.hasContent) {
                paste()
            }
            iconButton(symbol: "character.cursor.ibeam",  help: "이름 바꾸기 (F2)",
                       disabled: nav.selectedItems.count != 1) {
                if let url = nav.selectedItems.first {
                    DispatchQueue.main.async { nav.renamingURL = url }
                }
            }
            iconButton(symbol: "square.and.arrow.up",     help: "공유",
                       disabled: nav.selectedItems.isEmpty) {
                showSharingPicker(orderedSelection())
            }
            iconButton(symbol: "trash",                   help: "삭제 (Delete)",
                       disabled: nav.selectedItems.isEmpty) {
                deleteSelected()
            }

            Spacer()

            // Right side: labelled dropdowns (정렬, 보기) + overflow + preview toggle
            sortMenu
            viewMenu
            moreMenu
            previewToggle
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(red: 0.96, green: 0.96, blue: 0.96))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Left side new button

    private var newButton: some View {
        Menu {
            Button("폴더") { createNewFolder() }
            Divider()
            Button("텍스트 문서") { createNewFile(name: "새 텍스트 문서.txt") }
            Button("Markdown 문서") { createNewFile(name: "새 문서.md") }
            Button("리치 텍스트 문서") { createNewFile(name: "새 문서.rtf") }
            Button("Shell 스크립트") { createNewFile(name: "새 스크립트.sh") }
            Button("HTML 문서") { createNewFile(name: "새 문서.html") }
            Button("JSON 파일") { createNewFile(name: "새 데이터.json") }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("새로 만들기")
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Color(white: 0.4))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(HoverButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Right side menus (labelled)

    private var sortMenu: some View {
        Menu {
            ForEach(SortField.allCases, id: \.self) { field in
                Button {
                    let asc = nav.sortField == field ? nav.sortAscending : true
                    nav.applySort(field: field, ascending: asc)
                } label: {
                    HStack {
                        if nav.sortField == field { Image(systemName: "checkmark") }
                        Text(field.rawValue)
                    }
                }
            }
            Divider()
            Button {
                nav.applySortDirection(ascending: true)
            } label: {
                HStack {
                    if nav.sortAscending { Image(systemName: "checkmark") }
                    Text("오름차순")
                }
            }
            Button {
                nav.applySortDirection(ascending: false)
            } label: {
                HStack {
                    if !nav.sortAscending { Image(systemName: "checkmark") }
                    Text("내림차순")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12))
                Text("정렬")
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Color(white: 0.4))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(HoverButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var viewMenu: some View {
        Menu {
            ForEach(ViewMode.allCases) { mode in
                Button {
                    nav.viewMode = mode
                } label: {
                    HStack {
                        if nav.viewMode == mode { Image(systemName: "checkmark") }
                        Image(systemName: mode.symbol)
                        Text(mode.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModeSymbol)
                    .font(.system(size: 12))
                Text("보기")
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Color(white: 0.4))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(HoverButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var moreMenu: some View {
        Menu {
            // Selection
            Button("모두 선택") {
                nav.selectedItems = Set(nav.filteredItems.map { $0.url })
            }
            .keyboardShortcut("a", modifiers: .command)
            Button("선택 안 함") { nav.selectedItems.removeAll() }
            Button("선택 영역 반전") {
                let all = Set(nav.filteredItems.map { $0.url })
                nav.selectedItems = all.subtracting(nav.selectedItems)
            }

            Divider()

            // Display options — persisted across launches via PreferencesService
            Button {
                nav.showHidden.toggle()
            } label: {
                HStack {
                    if nav.showHidden { Image(systemName: "checkmark") }
                    Image(systemName: "eye")
                    Text("숨긴 파일 보기")
                }
            }

            Divider()

            Button("새로 고침") { nav.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("폴더에서 새 터미널 열기") { openTerminal(nav.currentURL) }
            Button("Finder에서 열기") { FileSystemService.shared.revealInFinder(nav.currentURL) }

            Divider()

            Button("현재 폴더를 빠른 액세스에 핀 고정") {
                PinnedFoldersService.shared.pin(nav.currentURL)
            }
            Button("현재 경로 복사") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(nav.currentURL.path, forType: .string)
            }
            Divider()
            Button("속성") { showCurrentFolderProperties() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(HoverButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var previewToggle: some View {
        Button {
            // Quick Look on selection (Space). Otherwise no preview pane (yet).
            let urls = orderedSelection()
            if urls.isEmpty,
               let first = nav.filteredItems.first {
                QuickLookCoordinator.shared.toggle(urls: [first.url])
            } else if !urls.isEmpty {
                QuickLookCoordinator.shared.toggle(urls: urls)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "eye")
                    .font(.system(size: 12))
                Text("미리 보기")
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help("Quick Look (Space)")
    }

    // MARK: - Building blocks

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
    }

    private var viewModeSymbol: String {
        switch nav.viewMode {
        case .details: return "list.dash"
        case .list:    return "list.bullet"
        case .smallIcons, .mediumIcons, .largeIcons, .extraLargeIcons: return "square.grid.2x2"
        case .tiles:   return "rectangle.grid.2x2"
        case .content: return "doc.text.below.ecg"
        }
    }

    private func iconButton(symbol: String, help: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundColor(disabled ? Color(white: 0.65) : .primary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .disabled(disabled)
        .help(help)
    }

    // MARK: - Actions

    private func orderedSelection() -> [URL] {
        nav.filteredItems.filter { nav.selectedItems.contains($0.url) }.map { $0.url }
    }

    private func paste() {
        do {
            let created = try ClipboardService.shared.paste(into: nav.currentURL)
            nav.reload(thenSelect: Set(created))
        } catch {
            commandAlert("붙여넣기 실패", error.localizedDescription)
        }
    }

    private func deleteSelected() {
        let urls = orderedSelection()
        guard !urls.isEmpty else { return }
        var firstErr: Error?
        for url in urls {
            do { try FileSystemService.shared.moveToTrash(url) } catch {
                if firstErr == nil { firstErr = error }
            }
        }
        nav.selectedItems.removeAll()
        nav.reload()
        if let err = firstErr {
            commandAlert("휴지통 이동 실패", err.localizedDescription)
        }
    }

    private func createNewFolder() {
        let url = uniqueInCurrent("새 폴더")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            nav.reload(thenSelect: [url])
        } catch {
            commandAlert("폴더 만들기 실패", error.localizedDescription)
        }
    }

    private func createNewFile(name: String) {
        let url = uniqueInCurrent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            commandAlert("파일 만들기 실패", url.path)
            return
        }
        nav.reload(thenSelect: [url])
    }

    private func uniqueInCurrent(_ name: String) -> URL {
        let fm = FileManager.default
        var candidate = nav.currentURL.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        repeat {
            let new = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = nav.currentURL.appendingPathComponent(new)
            i += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private func showSharingPicker(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let rect = NSRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 1, height: 1)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    private func openTerminal(_ url: URL) {
        let candidates = [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/iTerm.app"
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path),
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    private func showCurrentFolderProperties() {
        let url = nav.currentURL
        let alert = NSAlert()
        alert.messageText = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        var lines: [String] = []
        lines.append("종류: 폴더")
        lines.append("경로: \(url.path)")
        let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
        lines.append("항목 수: \(count)")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}

private struct HoverButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Color.gray.opacity(0.25)
                          : hovering ? Color.gray.opacity(0.15)
                          : Color.clear)
            )
            .onHover { hovering = $0 }
    }
}

private func commandAlert(_ title: String, _ msg: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = msg
    alert.alertStyle = .warning
    alert.addButton(withTitle: "확인")
    alert.runModal()
}
