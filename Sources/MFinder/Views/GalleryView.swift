import SwiftUI
import AppKit

/// Gallery view (갤러리): a large Quick Look preview of the focused item on top,
/// with a horizontal thumbnail filmstrip underneath — mirrors Finder's Gallery.
struct GalleryView: View {
    @EnvironmentObject var nav: NavigationState
    @ObservedObject private var themes = ThemeService.shared

    /// The item shown large: the first selected, else the first in the folder.
    private var focused: FileItem? {
        nav.filteredItems.first { nav.selectedItems.contains($0.url) } ?? nav.filteredItems.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item = focused {
                QuickLookPreview(url: item.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                Text(item.displayName)
                    .font(.system(size: themes.fontSize, weight: .semibold))
                    .foregroundColor(themes.theme.text.color)
                    .lineLimit(1)
                    .padding(.bottom, 2)
                Text(item.isDirectory ? item.typeDescription : "\(item.typeDescription) · \(item.sizeString)")
                    .font(.system(size: themes.secondaryFontSize))
                    .foregroundColor(themes.theme.secondaryText.color)
                    .lineLimit(1)
                    .padding(.bottom, 8)
            } else {
                Spacer()
                Text(L("미리 볼 항목을 선택하세요"))
                    .font(.system(size: themes.secondaryFontSize))
                    .foregroundColor(themes.theme.secondaryText.color)
                Spacer()
            }

            Divider()
            filmstrip
                .frame(height: 112)
                .background(themes.theme.barBackground.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themes.theme.contentBackground.color)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(nav.filteredItems) { item in
                        let isSel = nav.selectedItems.contains(item.url)
                        VStack(spacing: 4) {
                            IconView(item: item, size: 64)
                            Text(item.displayName)
                                .font(.system(size: 10))
                                .foregroundColor(isSel ? .white : themes.theme.text.color)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 84)
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSel ? themes.theme.selection.color : Color.clear)
                        )
                        .id(item.url)
                        .onTapGesture(count: 2) { open(item) }
                        .onTapGesture { nav.selectedItems = [item.url] }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: nav.selectedItems) { sel in
                if let first = nav.filteredItems.first(where: { sel.contains($0.url) }) {
                    withAnimation { proxy.scrollTo(first.url, anchor: .center) }
                }
            }
        }
    }

    private func open(_ item: FileItem) {
        if item.isDirectory {
            nav.navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }
}
