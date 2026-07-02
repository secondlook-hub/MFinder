import SwiftUI

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
                    .help("새 탭 (⌘T)")
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

    private var displayName: String {
        let name = nav.currentURL.lastPathComponent
        if name.isEmpty || name == "/" { return "내 PC" }
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
            isActive
                ? themes.theme.contentBackground.color
                : (hovering ? themes.theme.barBackground.blended(toward: themes.theme.contentBackground, fraction: 0.5).color : Color.clear)
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
        .contextMenu {
            Button("새 탭")        { onNewTab() }
            Button("탭 복제")      { onDuplicate() }
            Divider()
            Button("이 탭 닫기")   { onClose() }
                .disabled(!canClose)
            Button("다른 탭 모두 닫기") { onCloseOthers() }
                .disabled(!canClose)
        }
        .help(nav.currentURL.path)
    }
}
