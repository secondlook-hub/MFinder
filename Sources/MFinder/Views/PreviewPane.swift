import SwiftUI
import AppKit
import Quartz

/// Explorer-style docked preview pane (보기 → 미리 보기 패널, ⇧⌘P).
/// Renders the first selected item with Quick Look and lists its key
/// attributes underneath. Selection changes swap the preview in place.
struct PreviewPane: View {
    @EnvironmentObject var nav: NavigationState
    @ObservedObject private var themes = ThemeService.shared

    /// First selected item in list order (Set iteration order is unstable).
    private var selectedItem: FileItem? {
        nav.filteredItems.first { nav.selectedItems.contains($0.url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item = selectedItem {
                QuickLookPreviewRepresentable(url: item.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: themes.fontSize, weight: .semibold))
                        .foregroundColor(themes.theme.text.color)
                        .lineLimit(2)
                    Text(item.typeDescription)
                        .font(.system(size: themes.secondaryFontSize))
                        .foregroundColor(themes.theme.secondaryText.color)
                    if !item.isDirectory {
                        Text("크기: \(item.sizeString)")
                            .font(.system(size: themes.secondaryFontSize))
                            .foregroundColor(themes.theme.secondaryText.color)
                    }
                    Text("수정한 날짜: \(item.modificationString)")
                        .font(.system(size: themes.secondaryFontSize))
                        .foregroundColor(themes.theme.secondaryText.color)
                    Text("만든 날짜: \(item.creationString)")
                        .font(.system(size: themes.secondaryFontSize))
                        .foregroundColor(themes.theme.secondaryText.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "eye")
                        .font(.system(size: 28))
                        .foregroundColor(themes.theme.secondaryText.color)
                    Text("미리 볼 항목을 선택하세요")
                        .font(.system(size: themes.secondaryFontSize))
                        .foregroundColor(themes.theme.secondaryText.color)
                        .padding(.top, 6)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(themes.theme.contentBackground.color)
    }
}

/// QLPreviewView wrapper. `close()` on teardown releases the Quick Look
/// resources (per Apple docs the view leaks its preview otherwise).
private struct QuickLookPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != (url as NSURL) {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
