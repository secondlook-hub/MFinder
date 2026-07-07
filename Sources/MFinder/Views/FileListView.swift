import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileListView: View {
    @EnvironmentObject var nav: NavigationState
    @ObservedObject private var clipboard = ClipboardService.shared
    @ObservedObject private var themes = ThemeService.shared

    var body: some View {
        Group {
            switch nav.viewMode {
            case .details:          FileTableView(nav: nav)
            case .list:             listView
            case .smallIcons:       iconsView(size: 16)
            case .mediumIcons:      iconsView(size: 48)
            case .largeIcons:       iconsView(size: 72)
            case .extraLargeIcons:  iconsView(size: 96)
            case .tiles:            tilesView
            case .content:          contentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themes.theme.contentBackground.color)
        .contextMenu { emptySpaceMenu() }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderRenameSelected)) { _ in
            // Triggered by F2 — start rename of the single selected item.
            // Skip when the sidebar tree has focus so the tree handler can run.
            guard AppFocus.area == .fileList else { return }
            guard nav.renamingURL == nil,
                  nav.selectedItems.count == 1,
                  let url = nav.selectedItems.first else { return }
            nav.renamingURL = url
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderTrashSelected)) { _ in
            guard AppFocus.area == .fileList else { return }
            trashSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderGetInfo)) { _ in
            // ⌘I — properties of the first selected item (list order), or of
            // the current folder when nothing is selected. Skip when the
            // sidebar tree has focus so its own handler (async folder size)
            // can run.
            guard AppFocus.area != .sidebar else { return }
            if let item = nav.filteredItems.first(where: { nav.selectedItems.contains($0.url) }) {
                showProperties(item)
            } else {
                showFolderProperties(nav.currentURL)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderEmptyTrash)) { _ in
            emptyTrash()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderDeleteImmediately)) { _ in
            guard AppFocus.area == .fileList else { return }
            deleteImmediatelySelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderQuickLook)) { _ in
            let urls: [URL]
            if !nav.selectedItems.isEmpty {
                // Preserve sidebar list order rather than Set iteration order.
                urls = nav.filteredItems.filter { nav.selectedItems.contains($0.url) }.map(\.url)
            } else if let first = nav.filteredItems.first {
                urls = [first.url]
            } else {
                urls = []
            }
            guard !urls.isEmpty else { return }
            QuickLookCoordinator.shared.toggle(urls: urls)
        }
    }

    // MARK: - List view

    private var listView: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 1) {
                let cols = chunked(nav.filteredItems, perColumn: 20)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(col) { item in
                                listRow(item)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func listRow(_ item: FileItem) -> some View {
        let selected = nav.selectedItems.contains(item.url)
        let renaming = nav.renamingURL == item.url
        let cut = clipboard.isCut(item.url)
        return HStack(spacing: 4) {
            IconView(image: item.icon, size: 16)
            if renaming {
                RenameTextField(
                    item: item,
                    fontSize: themes.fontSize,
                    alignment: .left,
                    onCommit: { commitRename(item, newName: $0) },
                    onCancel: { nav.renamingURL = nil }
                )
                .frame(width: 170, height: themes.fontSize + 6)
            } else {
                Text(item.name)
                    .font(.system(size: themes.fontSize))
                    .foregroundColor(themes.theme.text.color)
                    .lineLimit(1)
            }
        }
        .opacity(cut ? 0.45 : 1.0)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(width: 200, alignment: .leading)
        .background(selected && !renaming ? themes.theme.selection.color : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(item) }
        .onTapGesture { handleClick(item) }
        .onDrag { dragItem(for: item) }
        .contextMenu { fileItemMenu(item) }
    }

    // MARK: - Icons view

    private func iconsView(size: CGFloat) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: size + 24), spacing: 8)],
                spacing: 12
            ) {
                ForEach(nav.filteredItems) { item in
                    iconCell(item, size: size)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
        }
    }

    private func iconCell(_ item: FileItem, size: CGFloat) -> some View {
        let selected = nav.selectedItems.contains(item.url)
        let renaming = nav.renamingURL == item.url
        let cut = clipboard.isCut(item.url)
        return VStack(spacing: 4) {
            IconView(image: item.icon, size: size)
            if renaming {
                RenameTextField(
                    item: item,
                    fontSize: themes.secondaryFontSize,
                    alignment: .center,
                    onCommit: { commitRename(item, newName: $0) },
                    onCancel: { nav.renamingURL = nil }
                )
                .frame(width: max(size + 24, 100), height: 36)
            } else {
                Text(item.name)
                    .font(.system(size: themes.secondaryFontSize))
                    .foregroundColor(themes.theme.text.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: size + 16)
            }
        }
        .opacity(cut ? 0.45 : 1.0)
        .padding(4)
        .background(selected && !renaming ? themes.theme.selection.color : Color.clear)
        .cornerRadius(2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(item) }
        .onTapGesture { handleClick(item) }
        .onDrag { dragItem(for: item) }
        .contextMenu { fileItemMenu(item) }
    }

    // MARK: - Tiles view

    private var tilesView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260), spacing: 8)],
                spacing: 6
            ) {
                ForEach(nav.filteredItems) { item in
                    tileCell(item)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
        }
    }

    private func tileCell(_ item: FileItem) -> some View {
        let selected = nav.selectedItems.contains(item.url)
        let renaming = nav.renamingURL == item.url
        let cut = clipboard.isCut(item.url)
        return HStack(spacing: 8) {
            IconView(image: item.icon, size: 48)
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    RenameTextField(
                        item: item,
                        fontSize: themes.fontSize,
                        alignment: .left,
                        onCommit: { commitRename(item, newName: $0) },
                        onCancel: { nav.renamingURL = nil }
                    )
                    .frame(height: 20)
                } else {
                    Text(item.name).font(.system(size: themes.fontSize, weight: .semibold)).foregroundColor(themes.theme.text.color).lineLimit(1)
                }
                Text(item.typeDescription).font(.system(size: themes.secondaryFontSize)).foregroundColor(themes.theme.secondaryText.color).lineLimit(1)
                if !item.isDirectory {
                    Text(item.sizeString).font(.system(size: themes.secondaryFontSize)).foregroundColor(themes.theme.secondaryText.color)
                }
            }
            Spacer()
        }
        .opacity(cut ? 0.45 : 1.0)
        .padding(6)
        .frame(height: 64)
        .background(selected && !renaming ? themes.theme.selection.color : Color.clear)
        .cornerRadius(2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(item) }
        .onTapGesture { handleClick(item) }
        .onDrag { dragItem(for: item) }
        .contextMenu { fileItemMenu(item) }
    }

    // MARK: - Content view

    private var contentView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(nav.filteredItems) { item in
                    let selected = nav.selectedItems.contains(item.url)
                    let renaming = nav.renamingURL == item.url
                    let cut = clipboard.isCut(item.url)
                    HStack(alignment: .top, spacing: 10) {
                        IconView(image: item.icon, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            if renaming {
                                RenameTextField(
                                    item: item,
                                    fontSize: themes.fontSize,
                                    alignment: .left,
                                    onCommit: { commitRename(item, newName: $0) },
                                    onCancel: { nav.renamingURL = nil }
                                )
                                .frame(height: 22)
                            } else {
                                Text(item.name).font(.system(size: themes.fontSize, weight: .semibold)).foregroundColor(themes.theme.text.color)
                            }
                            HStack(spacing: 16) {
                                Text("수정한 날짜: \(item.modificationString)")
                                Text(item.typeDescription)
                                if !item.isDirectory {
                                    Text("크기: \(item.sizeString)")
                                }
                            }
                            .font(.system(size: themes.secondaryFontSize))
                            .foregroundColor(themes.theme.secondaryText.color)
                        }
                        Spacer()
                    }
                    .opacity(cut ? 0.45 : 1.0)
                    .padding(8)
                    .background(selected && !renaming ? themes.theme.selection.color : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(item) }
                    .onTapGesture { handleClick(item) }
                    .contextMenu { fileItemMenu(item) }
                    Divider().opacity(0.3)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Context menus (Windows Explorer + Finder + Bandizip)

    @ViewBuilder
    private func fileItemMenu(_ item: FileItem) -> some View {
        let targets = currentTargets(for: item)

        // ── Open
        Button("열기") { targets.forEach { url in openURL(url) } }
            .keyboardShortcut(.return, modifiers: [])

        if item.isDirectory {
            Button("새 탭에서 열기") {
                NotificationCenter.default.post(name: .mfinderNewTab, object: item.url)
            }
            Button("새 창에서 열기") { FileSystemService.shared.openItem(item.url) }
        } else {
            Menu("연결 프로그램") {
                ForEach(applications(for: item.url), id: \.path) { appURL in
                    Button(appURL.deletingPathExtension().lastPathComponent) {
                        openWith(items: targets, app: appURL)
                    }
                }
                Divider()
                Button("App Store…") { NSWorkspace.shared.open(URL(string: "macappstore://")!) }
                Button("다른 앱 선택…") { chooseAppAndOpen(targets) }
            }
        }
        Button("빠른 보기") { quickLook(targets) }
            .keyboardShortcut(.space, modifiers: [])

        Button("정보 가져오기") { showProperties(item) }
            .keyboardShortcut("i", modifiers: .command)

        if item.isDirectory {
            Button("폴더에서 새 터미널 열기") { openTerminal(at: item.url) }
            Button("폴더에서 새 VS Code 열기") { openInEditor(item.url, bundleId: "com.microsoft.VSCode") }
        }

        Divider()

        // ── Clipboard
        Button("잘라내기") { ClipboardService.shared.cut(targets) }
            .keyboardShortcut("x", modifiers: .command)
        Button("복사") { ClipboardService.shared.copy(targets) }
            .keyboardShortcut("c", modifiers: .command)
        Button("붙여넣기") { pasteIntoCurrentFolder() }
        .keyboardShortcut("v", modifiers: .command)
        .disabled(!clipboard.hasContent)
        Button("바로 가기 만들기") { createAliases(targets) }
        Menu("복사: 추가 옵션") {
            Button("이름만 복사") { copyToPasteboard(targets.map { $0.lastPathComponent }.joined(separator: "\n")) }
            Button("전체 경로 복사") { copyToPasteboard(targets.map { $0.path }.joined(separator: "\n")) }
            Button("file:// URL 복사") { copyToPasteboard(targets.map { $0.absoluteString }.joined(separator: "\n")) }
            Button("UNIX 경로 (쉘 이스케이프) 복사") {
                copyToPasteboard(targets.map { "'\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " "))
            }
        }

        Menu("새로 만들기") {
            Button("폴더") { createNewFolder() }
            Divider()
            Button("텍스트 문서") { createNewFile(name: "새 텍스트 문서.txt") }
            Button("Markdown 문서") { createNewFile(name: "새 문서.md") }
            Button("리치 텍스트 문서") { createNewFile(name: "새 문서.rtf") }
            Button("Shell 스크립트") { createNewFile(name: "새 스크립트.sh") }
            Button("HTML 문서") { createNewFile(name: "새 문서.html") }
            Button("JSON 파일") { createNewFile(name: "새 데이터.json") }
        }

        Divider()

        // ── Rename / Delete
        Button("이름 바꾸기") {
            DispatchQueue.main.async { nav.renamingURL = item.url }
        }
        .keyboardShortcut(.return, modifiers: .command)
        if targets.count > 1 {
            Button("일괄 이름 바꾸기 (\(targets.count)개)…") {
                // Preserve list order for numbering (Set order is unstable).
                let ordered = nav.filteredItems.map(\.url).filter(Set(targets).contains)
                promptBatchRename(ordered, nav: nav)
            }
        }
        Button("휴지통으로 이동", role: .destructive) {
            var trashed: [URL] = []
            for url in targets where (try? FileSystemService.shared.moveToTrash(url)) != nil {
                trashed.append(url)
            }
            UndoService.shared.register(.trash(originals: trashed), label: "휴지통으로 이동")
            nav.selectedItems.subtract(targets)
            nav.reload()
        }
        .keyboardShortcut(.delete)
        Button("영구 삭제", role: .destructive) { permanentDelete(targets) }
            .keyboardShortcut(.delete, modifiers: .shift)

        Divider()

        // ── Send To
        Menu("보내기") {
            Button("바탕 화면 (바로 가기 만들기)") { sendToDesktopShortcut(targets) }
            Button("다운로드 폴더") { copyURLs(targets, to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) }
            Button("문서 폴더") { copyURLs(targets, to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")) }
            Divider()
            Button("AirDrop") { airDrop(targets) }
            Button("메일 수신자") { mailURLs(targets) }
            Button("메시지") { shareVia(.composeMessage, urls: targets) }
            Divider()
            Button("압축 (Zip) 폴더") { compressTargets(targets, format: .zip) }
        }

        Divider()

        // ── Bandizip-style submenu
        Menu("Bandizip") {
            Section("압축") {
                ForEach(ArchiveFormat.allCases, id: \.self) { fmt in
                    if ArchiveService.shared.canCompress(to: fmt) {
                        Button("\(suggestedArchiveName(for: targets, ext: fmt.rawValue))(으)로 압축") {
                            compressTargets(targets, format: fmt)
                        }
                    }
                }
                Button("압축하고 이메일 보내기…") {
                    compressAndMail(targets)
                }
            }
            if targets.count == 1, ArchiveService.shared.isArchive(targets[0]) {
                Section("압축 풀기") {
                    Button("여기에 압축 풀기") { extractHere(targets[0]) }
                    Button("\"\(ArchiveService.shared.basename(ofArchive: targets[0]))\" 폴더에 압축 풀기") {
                        extractToFolder(targets[0])
                    }
                    Button("압축 풀 위치 선택…") { extractToCustomFolder(targets[0]) }
                    Divider()
                    Button("미리 보기") { quickLook([targets[0]]) }
                    Button("압축 파일 검사") { testArchive(targets[0]) }
                    Button("압축 파일 정보 보기") { archiveInfo(targets[0]) }
                }
            }
        }

        Divider()

        // ── Share / Tags
        Menu("공유") {
            Button("AirDrop") { airDrop(targets) }
            Button("메일") { shareVia(.composeEmail, urls: targets) }
            Button("메시지") { shareVia(.composeMessage, urls: targets) }
            Button("Safari 리딩 리스트에 추가") { shareVia(.addToSafariReadingList, urls: targets) }
            Divider()
            Button("공유 시트 표시…") { showSharingPicker(targets) }
        }
        Button("태그…") { promptTags(targets) }

        Divider()

        // ── Finder
        Button("Finder에서 보기") { FileSystemService.shared.revealInFinder(item.url) }
        Button("속성") { showProperties(item) }
    }

    @ViewBuilder
    private func emptySpaceMenu() -> some View {
        Menu("보기") {
            ForEach(ViewMode.allCases) { mode in
                Button {
                    nav.viewMode = mode
                } label: {
                    HStack {
                        if nav.viewMode == mode { Image(systemName: "checkmark") }
                        Text(mode.rawValue)
                    }
                }
            }
        }

        Menu("정렬 기준") {
            ForEach(SortField.allCases, id: \.self) { field in
                Button {
                    nav.applySort(field: field, ascending: nav.sortField == field ? nav.sortAscending : true)
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
        }

        Menu("그룹화 기준") {
            ForEach(GroupField.allCases, id: \.self) { field in
                Button {
                    nav.groupField = field
                } label: {
                    HStack {
                        if nav.groupField == field { Image(systemName: "checkmark") }
                        Text(field.rawValue)
                    }
                }
            }
        }

        Button("새로 고침") { nav.reload() }
            .keyboardShortcut("r", modifiers: .command)

        Divider()

        Button("붙여넣기") { pasteIntoCurrentFolder() }
        .keyboardShortcut("v", modifiers: .command)
        .disabled(!ClipboardService.shared.hasContent)

        Button("바로 가기 붙여넣기") { pasteAsShortcut() }
            .disabled(!ClipboardService.shared.hasContent)

        Button("실행 취소") { UndoService.shared.undo() }
            .keyboardShortcut("z", modifiers: .command)

        Divider()

        Menu("새로 만들기") {
            Button("폴더") { createNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("텍스트 문서") { createNewFile(name: "새 텍스트 문서.txt") }
            Button("Markdown 문서") { createNewFile(name: "새 문서.md") }
            Button("리치 텍스트 문서") { createNewFile(name: "새 문서.rtf") }
            Button("Shell 스크립트") { createNewFile(name: "새 스크립트.sh") }
            Button("HTML 문서") { createNewFile(name: "새 문서.html") }
            Button("JSON 파일") { createNewFile(name: "새 데이터.json") }
        }

        Divider()

        Menu("Bandizip") {
            Section("이 폴더 압축") {
                if ArchiveService.shared.canCompress(to: .zip) {
                    Button("이 폴더를 Zip으로 압축") {
                        compressFolderItself(nav.currentURL, format: .zip)
                    }
                }
                if ArchiveService.shared.canCompress(to: .tarGz) {
                    Button("이 폴더를 tar.gz로 압축") {
                        compressFolderItself(nav.currentURL, format: .tarGz)
                    }
                }
                if ArchiveService.shared.canCompress(to: .sevenZ) {
                    Button("이 폴더를 7z로 압축") {
                        compressFolderItself(nav.currentURL, format: .sevenZ)
                    }
                }
            }
        }

        Divider()

        Button("폴더에서 새 터미널 열기") { openTerminal(at: nav.currentURL) }
        Button("현재 경로 복사") { copyToPasteboard(nav.currentURL.path) }
        Button("Finder에서 열기") { FileSystemService.shared.revealInFinder(nav.currentURL) }

        Divider()

        Button("디스플레이 설정") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.displays")!) }
        Button("개인 설정") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.desktopscreeneffect")!) }

        Divider()

        Button("속성") { showFolderProperties(nav.currentURL) }
    }

    // MARK: - Menu actions

    private func pasteIntoCurrentFolder() {
        ClipboardService.shared.paste(into: nav.currentURL) { result in
            switch result {
            case .success(let created):
                nav.reload(thenSelect: Set(created))
            case .failure(let error):
                showError("붙여넣기 실패", message: error.localizedDescription)
            }
        }
    }

    private func currentTargets(for item: FileItem) -> [URL] {
        if nav.selectedItems.contains(item.url) {
            return Array(nav.selectedItems)
        }
        return [item.url]
    }

    private func openURL(_ url: URL) {
        if let item = nav.items.first(where: { $0.url == url }), item.isDirectory {
            nav.navigate(to: url)
        } else {
            FileSystemService.shared.openItem(url)
        }
    }

    private func applications(for url: URL) -> [URL] {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: url)
        return Array(urls.prefix(8))
    }

    private func openWith(items: [URL], app: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(items, withApplicationAt: app, configuration: cfg) { _, _ in }
    }

    private func chooseAppAndOpen(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let app = panel.url {
            openWith(items: urls, app: app)
        }
    }

    private func editURLs(_ urls: [URL]) {
        // Open with TextEdit
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        if FileManager.default.fileExists(atPath: textEdit.path) {
            openWith(items: urls, app: textEdit)
        } else {
            urls.forEach { FileSystemService.shared.openItem($0) }
        }
    }

    private func copyURLs(_ urls: [URL], to dir: URL) {
        let fm = FileManager.default
        for src in urls {
            let dst = unique(src.lastPathComponent, in: dir)
            try? fm.copyItem(at: src, to: dst)
        }
        nav.reload()
    }

    private func sendToDesktopShortcut(_ urls: [URL]) {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        for src in urls {
            let dst = unique("\(src.lastPathComponent) 바로 가기", in: desktop)
            try? FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
        }
    }

    // MARK: - Archive actions (Bandizip-style)

    private func suggestedArchiveName(for urls: [URL], ext: String) -> String {
        let folderName = nav.currentURL.lastPathComponent
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

    private func compressTargets(_ urls: [URL], format: ArchiveFormat) {
        guard !urls.isEmpty else { return }
        let name = suggestedArchiveName(for: urls, ext: format.rawValue)
        let uniqueName = unique(name, in: nav.currentURL).lastPathComponent
        do {
            try ArchiveService.shared.compress(urls, into: nav.currentURL, archiveName: uniqueName, format: format)
            nav.reload()
        } catch {
            showError("압축 실패", message: error.localizedDescription)
        }
    }

    private func compressFolderItself(_ folder: URL, format: ArchiveFormat) {
        let parent = folder.deletingLastPathComponent()
        let name = "\(folder.lastPathComponent).\(format.rawValue)"
        let uniqueName = unique(name, in: parent).lastPathComponent
        do {
            try ArchiveService.shared.compress([folder], into: parent, archiveName: uniqueName, format: format)
            nav.reload()
        } catch {
            showError("압축 실패", message: error.localizedDescription)
        }
    }

    private func compressAndMail(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let name = suggestedArchiveName(for: urls, ext: "zip")
        let uniqueName = unique(name, in: nav.currentURL).lastPathComponent
        let dst = nav.currentURL.appendingPathComponent(uniqueName)
        do {
            try ArchiveService.shared.compress(urls, into: nav.currentURL, archiveName: uniqueName, format: .zip)
            nav.reload()
            shareVia(.composeEmail, urls: [dst])
        } catch {
            showError("압축 실패", message: error.localizedDescription)
        }
    }

    private func extractHere(_ url: URL) {
        do {
            try ArchiveService.shared.extractHere(url)
            nav.reload()
        } catch {
            showError("압축 풀기 실패", message: error.localizedDescription)
        }
    }

    private func extractToFolder(_ url: URL) {
        do {
            _ = try ArchiveService.shared.extractIntoFolder(url)
            nav.reload()
        } catch {
            showError("압축 풀기 실패", message: error.localizedDescription)
        }
    }

    private func extractToCustomFolder(_ url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.message = "압축을 풀 위치를 선택하세요"
        if panel.runModal() == .OK, let dst = panel.url {
            do {
                try ArchiveService.shared.extract(url, into: dst)
                nav.reload()
            } catch {
                showError("압축 풀기 실패", message: error.localizedDescription)
            }
        }
    }

    private func testArchive(_ url: URL) {
        do {
            let result = try ArchiveService.shared.testArchive(url)
            showLongAlert(title: "압축 파일 검사", text: result.isEmpty ? "이상 없음." : result)
        } catch {
            showError("검사 실패", message: error.localizedDescription)
        }
    }

    private func archiveInfo(_ url: URL) {
        do {
            let result = try ArchiveService.shared.archiveInfo(url)
            showLongAlert(title: "압축 파일 정보 — \(url.lastPathComponent)", text: result)
        } catch {
            showError("정보 표시 실패", message: error.localizedDescription)
        }
    }

    // MARK: - Quick Look / Terminal / Editors

    private func quickLook(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        task.arguments = ["-p"] + urls.map { $0.path }
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
    }

    private func openTerminal(at url: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: terminal.path) {
            NSWorkspace.shared.open([url], withApplicationAt: terminal,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            // Try iTerm
            let iterm = URL(fileURLWithPath: "/Applications/iTerm.app")
            if FileManager.default.fileExists(atPath: iterm.path) {
                NSWorkspace.shared.open([url], withApplicationAt: iterm,
                                        configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
        }
    }

    private func openInEditor(_ url: URL, bundleId: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            showError("앱을 찾을 수 없습니다", message: "\(bundleId) 가 설치되지 않았습니다.")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: - Pasteboard

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    // MARK: - Share

    private func airDrop(_ urls: [URL]) {
        guard let svc = NSSharingService(named: .sendViaAirDrop) else { return }
        svc.perform(withItems: urls)
    }

    private func mailURLs(_ urls: [URL]) {
        shareVia(.composeEmail, urls: urls)
    }

    private func shareVia(_ name: NSSharingService.Name, urls: [URL]) {
        guard let svc = NSSharingService(named: name) else { return }
        svc.perform(withItems: urls)
    }

    private func showSharingPicker(_ urls: [URL]) {
        let picker = NSSharingServicePicker(items: urls)
        guard let window = NSApp.keyWindow,
              let view = window.contentView else { return }
        let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    // MARK: - Tags

    private func promptTags(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "태그"
        alert.informativeText = "쉼표로 구분하여 입력하세요 (예: 작업, 중요)."
        alert.addButton(withTitle: "적용")
        alert.addButton(withTitle: "취소")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let existing = (try? urls[0].resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        textField.stringValue = existing.joined(separator: ", ")
        alert.accessoryView = textField
        if alert.runModal() == .alertFirstButtonReturn {
            let tags = textField.stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for url in urls {
                let nsurl = url as NSURL
                try? nsurl.setResourceValue(tags as NSArray, forKey: .tagNamesKey)
            }
            nav.reload()
        }
    }

    // MARK: - Permanent delete

    private func permanentDelete(_ urls: [URL]) {
        let alert = NSAlert()
        alert.messageText = "영구 삭제하시겠습니까?"
        alert.informativeText = "이 작업은 되돌릴 수 없습니다. \(urls.count)개 항목이 영구적으로 삭제됩니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            for url in urls { try? FileManager.default.removeItem(at: url) }
            nav.selectedItems.subtract(urls)
            nav.reload()
        }
    }

    // MARK: - Folder properties

    private func showFolderProperties(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        var lines: [String] = []
        lines.append("종류: 폴더")
        lines.append("경로: \(url.path)")
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let m = values.contentModificationDate {
                lines.append("수정한 날짜: \(f.string(from: m))")
            }
            if let c = values.creationDate {
                lines.append("만든 날짜: \(f.string(from: c))")
            }
        }
        let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
        lines.append("항목 수: \(count)")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "Finder에서 보기")
        if alert.runModal() == .alertSecondButtonReturn {
            FileSystemService.shared.revealInFinder(url)
        }
    }

    // MARK: - Alert helpers

    private func showError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func showLongAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "확인")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        textView.isEditable = false
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.runModal()
    }

    private func createAliases(_ urls: [URL]) {
        var created: [URL] = []
        for src in urls {
            let dst = unique("\(src.lastPathComponent) 바로 가기", in: nav.currentURL)
            if (try? FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)) != nil {
                created.append(dst)
            }
        }
        UndoService.shared.register(.create(urls: created), label: "바로 가기 만들기")
        nav.reload()
    }

    private func pasteAsShortcut() {
        let pb = NSPasteboard.general
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] else { return }
        for src in urls {
            let dst = unique("\(src.lastPathComponent) 바로 가기", in: nav.currentURL)
            try? FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
        }
        nav.reload()
    }

    private func promptRename(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "이름 바꾸기"
        alert.informativeText = "새 이름을 입력하세요."
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = url.lastPathComponent
        alert.accessoryView = textField
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != url.lastPathComponent else { return }
            let dst = url.deletingLastPathComponent().appendingPathComponent(newName)
            try? FileManager.default.moveItem(at: url, to: dst)
            nav.reload()
        }
    }

    private func showProperties(_ item: FileItem) {
        let alert = NSAlert()
        alert.messageText = item.name
        var lines: [String] = []
        lines.append("종류: \(item.typeDescription)")
        lines.append("경로: \(item.url.path)")
        if !item.isDirectory {
            lines.append("크기: \(item.sizeString)")
        }
        lines.append("수정한 날짜: \(item.modificationString)")
        alert.informativeText = lines.joined(separator: "\n")
        alert.icon = item.icon
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "Finder에서 보기")
        if alert.runModal() == .alertSecondButtonReturn {
            FileSystemService.shared.revealInFinder(item.url)
        }
    }

    private func createNewFolder() {
        let url = unique("새 폴더", in: nav.currentURL)
        guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)) != nil else {
            nav.reload()
            return
        }
        UndoService.shared.register(.create(urls: [url]), label: "새로 만들기")
        nav.reload()
    }

    private func createNewFile(name: String) {
        let url = unique(name, in: nav.currentURL)
        if FileManager.default.createFile(atPath: url.path, contents: Data()) {
            UndoService.shared.register(.create(urls: [url]), label: "새로 만들기")
        }
        nav.reload()
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

    // MARK: - Selection / open

    private func open(_ item: FileItem) {
        switch FileSystemService.shared.openAction(for: item.url) {
        case .navigate(let target):
            nav.navigate(to: target)
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

    private func select(_ item: FileItem) {
        AppFocus.area = .fileList
        let mod = NSEvent.modifierFlags
        if mod.contains(.command) {
            if nav.selectedItems.contains(item.url) {
                nav.selectedItems.remove(item.url)
            } else {
                nav.selectedItems.insert(item.url)
            }
        } else {
            nav.selectedItems = [item.url]
        }
    }

    /// Click handler with Finder-style "click already-selected item → rename" behaviour.
    /// SwiftUI's onTapGesture only fires the single-tap after the double-click
    /// timeout, so a real double-click never reaches this path.
    private func handleClick(_ item: FileItem) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) || mods.contains(.shift) {
            select(item)
            return
        }
        if nav.renamingURL == nil && nav.selectedItems == [item.url] {
            nav.renamingURL = item.url
        } else {
            select(item)
        }
    }

    /// Wraps the row's URL into an NSItemProvider so SwiftUI's drag system
    /// publishes the file URL on the pasteboard. Other apps (Finder included)
    /// receive it as a standard file drop.
    private func dragItem(for item: FileItem) -> NSItemProvider {
        NSItemProvider(object: item.url as NSURL)
    }

    /// Move selected items to the Trash. Bound to ⌫ / ⌘⌫ via the global key monitor.
    /// Delegates to FileSystemService.moveToTrash which routes through Finder
    /// (via AppleScript) so files actually land in ~/.Trash on macOS 26.
    private func trashSelected() {
        let urls = nav.filteredItems.filter { nav.selectedItems.contains($0.url) }.map(\.url)
        guard !urls.isEmpty else { return }
        do {
            try FileSystemService.shared.moveToTrash(urls)
            UndoService.shared.register(.trash(originals: urls), label: "휴지통으로 이동")
            nav.selectedItems.subtract(urls)
            nav.reload()
        } catch {
            showSimpleAlert("휴지통 이동 실패", error.localizedDescription)
        }
    }

    /// Delete selected items immediately, bypassing the Trash. Bound to ⌥⌘⌫
    /// (Finder's "Delete Immediately"). Shows confirmation alert.
    private func deleteImmediatelySelected() {
        let urls = nav.filteredItems.filter { nav.selectedItems.contains($0.url) }.map(\.url)
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "즉시 삭제하시겠습니까?"
        alert.informativeText = "\(urls.count)개 항목이 휴지통을 거치지 않고 영구적으로 삭제됩니다. 이 작업은 되돌릴 수 없습니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

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
        nav.selectedItems.subtract(deleted)
        nav.reload()
        if let err = firstErr {
            showSimpleAlert("삭제 실패", err.localizedDescription)
        }
    }

    /// Empties the entire user Trash via Finder. Bound to ⌘⇧⌫ (Finder standard).
    /// Does not depend on file selection.
    private func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "휴지통을 비우시겠습니까?"
        alert.informativeText = "휴지통의 모든 항목이 영구적으로 삭제됩니다. 이 작업은 되돌릴 수 없습니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "휴지통 비우기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileSystemService.shared.emptyTrash()
        } catch {
            showSimpleAlert("휴지통 비우기 실패", error.localizedDescription)
        }
    }

    private func showSimpleAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    /// Commit handler shared by all SwiftUI view modes' RenameTextField instances.
    private func commitRename(_ item: FileItem, newName: String) {
        nav.renamingURL = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let dst = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: item.url, to: dst)
            UndoService.shared.register(.move(pairs: [(from: item.url, to: dst)]), label: "이름 바꾸기")
            nav.reload(thenSelect: [dst])
        } catch {
            let alert = NSAlert()
            alert.messageText = "이름 바꾸기 실패"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
    }

    private func chunked<T>(_ array: [T], perColumn: Int) -> [[T]] {
        guard perColumn > 0 else { return [array] }
        var result: [[T]] = []
        var i = 0
        while i < array.count {
            let end = min(i + perColumn, array.count)
            result.append(Array(array[i..<end]))
            i = end
        }
        return result
    }
}

struct IconView: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
