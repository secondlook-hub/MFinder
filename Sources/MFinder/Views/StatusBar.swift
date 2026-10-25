import SwiftUI

struct StatusBar: View {
    @EnvironmentObject var nav: NavigationState
    @ObservedObject private var clipboard = ClipboardService.shared
    @ObservedObject private var themes = ThemeService.shared
    @State private var showStackPopover = false

    var body: some View {
        HStack(spacing: 8) {
            let total = nav.filteredItems.count
            let sel = nav.selectedItems.count
            if !nav.searchText.isEmpty {
                if nav.isSearching {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        Text(Lf("\"%@\" 검색 중… (%@개 발견)", "\(nav.searchText)", "\(total)"))
                    }
                } else {
                    Text(Lf("\"%@\" 검색 결과 %@개", "\(nav.searchText)", "\(total)"))
                }
                if sel > 0 { Text(Lf("• %@개 선택", "\(sel)")) }
            } else if sel > 0 {
                Text(Lf("%@개 항목 선택", "\(sel)"))
                if let first = nav.filteredItems.first(where: { nav.selectedItems.contains($0.url) }), !first.isDirectory {
                    Text("•")
                    Text(first.sizeString)
                }
            } else {
                Text(Lf("%@개 항목", "\(total)"))
            }
            if !clipboard.stack.isEmpty {
                Text("•")
                clipboardPill
            }
            if let err = nav.errorMessage {
                Text("• \(err)").foregroundColor(.red)
            }
            Spacer()
            HStack(spacing: 4) {
                Button {
                    nav.viewMode = .details
                } label: {
                    Image(systemName: "list.dash")
                        .font(.system(size: 11))
                        .padding(2)
                        .background(nav.viewMode == .details ? themes.theme.accent.color.opacity(0.25) : Color.clear)
                }
                .buttonStyle(.plain)
                Button {
                    nav.viewMode = .largeIcons
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .padding(2)
                        .background(nav.viewMode == .largeIcons ? themes.theme.accent.color.opacity(0.25) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 11))
        .foregroundColor(themes.theme.text.color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(themes.theme.barBackground.color)
        .overlay(Divider(), alignment: .top)
    }

    /// Clickable pill that summarizes the clipboard stack. Tap → popover
    /// above with full list + per-row remove + paste-here / clear actions.
    private var clipboardPill: some View {
        Button {
            showStackPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: clipboardSymbol)
                    .font(.system(size: 10))
                Text(clipboardLabel)
                    .foregroundColor(themes.theme.text.color)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(showStackPopover ? 0.22 : 0.12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("클릭해서 스택 내용을 보고 한 번에 붙여넣기"))
        .popover(isPresented: $showStackPopover, arrowEdge: .bottom) {
            ClipboardStackView()
                .environmentObject(nav)
        }
    }

    private var clipboardSymbol: String {
        switch clipboard.dominantMode {
        case .some(true):  return "scissors"
        case .some(false): return "doc.on.doc"
        case .none:        return "rectangle.stack.fill"   // mixed
        }
    }

    private var clipboardLabel: String {
        let count = clipboard.stack.count
        switch clipboard.dominantMode {
        case .some(true):  return Lf("잘라낸 항목 %@개 대기", "\(count)")
        case .some(false): return Lf("복사한 항목 %@개 대기", "\(count)")
        case .none:        return Lf("복사/잘라낸 항목 %@개 대기", "\(count)")
        }
    }
}
