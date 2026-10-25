import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TabBar: View {
    @EnvironmentObject var tabs: TabsState
    @ObservedObject private var themes = ThemeService.shared

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(tabs.tabs.enumerated()), id: \.offset) { idx, nav in
                        TabCell(
                            nav: nav,
                            isActive: tabs.activeIndex == idx,
                            canClose: tabs.tabs.count > 1,
                            onSelect:       { tabs.selectTab(at: idx) },
                            onClose:        { tabs.closeTab(at: idx) },
                            onDuplicate:    { tabs.duplicateTab(at: idx) },
                            onCloseOthers:  { tabs.closeOtherTabs(at: idx) },
                            onNewTab:       { tabs.newTab() }
                        )
                    }

                    // Sits inside the scroll content so it hugs the last tab
                    // (browser style) instead of being pinned to the far right.
                    Button {
                        tabs.newTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(themes.theme.secondaryText.color)
                            .frame(width: 28, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("새 탭 (⌘T)"))
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .background(themes.theme.barBackground.color)
        .overlay(Divider(), alignment: .bottom)
    }
}

struct TabCell: View {
    @ObservedObject var nav: NavigationState
    @ObservedObject private var themes = ThemeService.shared
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    let onCloseOthers: () -> Void
    let onNewTab: () -> Void

    @State private var hovering = false
    // Drag-and-drop onto the tab: highlight while a file drag hovers, and a
    // spring-load timer that switches to this tab after a short dwell.
    @State private var isDropTarget = false
    @State private var springWork: DispatchWorkItem?

    private var displayName: String {
        let name = nav.currentURL.lastPathComponent
        if name.isEmpty || name == "/" { return L("내 PC") }
        return name
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.18))

            Text(displayName)
                .font(.system(size: 12))
                .foregroundColor(themes.theme.text.color)
                .lineLimit(1)
                .truncationMode(.tail)

            if canClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(themes.theme.secondaryText.color)
                        .frame(width: 14, height: 14)
                        .background(hovering ? Color.gray.opacity(0.25) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || isActive ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(minWidth: 100, maxWidth: 220)
        .background(
            isDropTarget
                ? themes.theme.accent.color.opacity(0.25)
                : (isActive
                    ? themes.theme.contentBackground.color
                    : (hovering ? themes.theme.barBackground.blended(toward: themes.theme.contentBackground, fraction: 0.5).color : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(themes.theme.accent.color, lineWidth: 1.5)
                .opacity(isDropTarget ? 1 : 0)
        )
        .overlay(
            // Right divider
            Rectangle()
                .fill(Color.gray.opacity(0.25))
                .frame(width: 1)
                .opacity(isActive ? 0 : 1),
            alignment: .trailing
        )
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(themes.theme.accent.color)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect() }
        .onDrop(of: [UTType.fileURL.identifier], delegate: TabDropDelegate(
            nav: nav,
            isActive: isActive,
            activate: onSelect,
            isTargeted: $isDropTarget,
            springWork: $springWork
        ))
        .contextMenu {
            Button(L("새 탭"))        { onNewTab() }
            Button(L("탭 복제"))      { onDuplicate() }
            Divider()
            Button(L("이 탭 닫기"))   { onClose() }
                .disabled(!canClose)
            Button(L("다른 탭 모두 닫기")) { onCloseOthers() }
                .disabled(!canClose)
        }
        .help(nav.currentURL.path)
    }
}

// MARK: - Drop onto a tab

/// Handles files dragged onto a tab. Two behaviors, both requested:
///   1. Dropping copies (⌥) or moves (default) the files into *that tab's*
///      folder, using the same conflict prompt + background progress panel as
///      paste and the file-list/sidebar drops.
///   2. Hovering over an inactive tab for a short dwell switches to it
///      (spring-loaded), so the user can drop into a folder they can see.
struct TabDropDelegate: DropDelegate {
    let nav: NavigationState
    let isActive: Bool
    let activate: () -> Void
    @Binding var isTargeted: Bool
    @Binding var springWork: DispatchWorkItem?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        // Spring-load: reveal an inactive tab after a brief dwell so the drop
        // target folder becomes visible before the release.
        guard !isActive else { return }
        springWork?.cancel()
        let work = DispatchWorkItem { activate() }
        springWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        springWork?.cancel()
        springWork = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        springWork?.cancel()
        springWork = nil
        isTargeted = false

        let copy = NSEvent.modifierFlags.contains(.option)
        let providers = info.itemProviders(for: [UTType.fileURL.identifier])
        guard !providers.isEmpty else { return false }
        let nav = self.nav
        loadDroppedURLs(from: providers) { urls in
            guard !urls.isEmpty else { return }
            // loadDroppedURLs delivers on the main thread.
            MainActor.assumeIsolated {
                performTabDrop(urls: urls, into: nav, copy: copy)
            }
        }
        return true
    }
}

/// Loads file URLs from the dropped item providers, preserving drop order,
/// and calls `completion` on the main thread.
private func loadDroppedURLs(from providers: [NSItemProvider],
                            completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var collected: [(Int, URL)] = []
    for (idx, provider) in providers.enumerated() {
        group.enter()
        _ = provider.loadObject(ofClass: NSURL.self) { obj, _ in
            if let url = obj as? URL {
                lock.lock(); collected.append((idx, url)); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        completion(collected.sorted { $0.0 < $1.0 }.map { $0.1 })
    }
}

/// Copies/moves `urls` into the tab's current folder — mirrors the sidebar and
/// file-table drop logic (self-drop guards, 덮어쓰기/건너뛰기/취소 prompt with a
/// blanket answer, background progress, undo registration, refresh).
@MainActor
private func performTabDrop(urls: [URL], into nav: NavigationState, copy: Bool) {
    let dst = nav.currentURL
    let fm = FileManager.default

    func uniqueChild(base: String) -> URL {
        var candidate = dst.appendingPathComponent(base)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let name = URL(fileURLWithPath: base).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: base).pathExtension
        var i = 2
        repeat {
            let new = ext.isEmpty ? "\(name) (\(i))" : "\(name) (\(i)).\(ext)"
            candidate = dst.appendingPathComponent(new)
            i += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    // Pre-count conflicts so each prompt can offer a blanket answer.
    var conflictsLeft = urls.filter { src in
        let s = src.standardizedFileURL, d = dst.standardizedFileURL
        guard s != d else { return false }
        if !copy, s.deletingLastPathComponent() == d { return false }
        let t = dst.appendingPathComponent(src.lastPathComponent)
        return t.standardizedFileURL != s && fm.fileExists(atPath: t.path)
    }.count

    var blanket: FileConflictChoice?
    var ops: [FileOperation] = []
    for src in urls {
        let s = src.standardizedFileURL, d = dst.standardizedFileURL
        if s == d { continue }
        // Move back into own folder = no-op; copy into own folder = duplicate.
        if !copy, s.deletingLastPathComponent() == d { continue }
        let plain = dst.appendingPathComponent(src.lastPathComponent)
        let target: URL
        if plain.standardizedFileURL == s {
            target = uniqueChild(base: src.lastPathComponent)
        } else {
            if fm.fileExists(atPath: plain.path) {
                conflictsLeft -= 1
                let choice = blanket ?? askFileConflict(name: src.lastPathComponent,
                                                        remainingConflicts: conflictsLeft,
                                                        blanket: &blanket)
                if choice == .skip { continue }
                if choice == .cancel { break }
                try? fm.removeItem(at: plain)
            }
            target = plain
        }
        ops.append(FileOperation(src: src, dst: target, isMove: !copy))
    }
    guard !ops.isEmpty else { return }

    FileOperationService.shared.perform(ops, title: copy ? "복사 중…" : "이동 중…") { done, err in
        let landed = done.map(\.dst)
        if copy {
            UndoService.shared.register(.create(urls: landed), label: "복사")
        } else {
            UndoService.shared.register(.move(pairs: done.map { (from: $0.src, to: $0.dst) }),
                                        label: "이동")
        }
        nav.tree.reloadChildren(of: dst)
        if dst.standardizedFileURL == nav.currentURL.standardizedFileURL {
            nav.reload(thenSelect: Set(landed))
        } else {
            nav.reload()
        }
        if let err, landed.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("드롭 실패")
            alert.informativeText = err.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("확인"))
            alert.runModal()
        }
    }
}
