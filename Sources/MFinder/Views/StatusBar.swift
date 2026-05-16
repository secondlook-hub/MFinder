import SwiftUI

struct StatusBar: View {
    @EnvironmentObject var nav: NavigationState
    @ObservedObject private var clipboard = ClipboardService.shared
    @State private var showStackPopover = false

    var body: some View {
        HStack(spacing: 8) {
            let total = nav.filteredItems.count
            let sel = nav.selectedItems.count
            if !nav.searchText.isEmpty {
                if nav.isSearching {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        Text("\"\(nav.searchText)\" 검색 중… (\(total)개 발견)")
                    }
                } else {
                    Text("\"\(nav.searchText)\" 검색 결과 \(total)개")
                }
                if sel > 0 { Text("• \(sel)개 선택") }
            } else if sel > 0 {
                Text("\(sel)개 항목 선택")
                if let first = nav.filteredItems.first(where: { nav.selectedItems.contains($0.url) }), !first.isDirectory {
                    Text("•")
                    Text(first.sizeString)
                }
            } else {
                Text("\(total)개 항목")
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
                        .background(nav.viewMode == .details ? Color.accentColor.opacity(0.25) : Color.clear)
                }
                .buttonStyle(.plain)
                Button {
                    nav.viewMode = .largeIcons
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .padding(2)
                        .background(nav.viewMode == .largeIcons ? Color.accentColor.opacity(0.25) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Color(nsColor: .windowBackgroundColor))
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
                    .foregroundColor(Color(white: 0.25))
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
        .help("클릭해서 스택 내용을 보고 한 번에 붙여넣기")
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
        case .some(true):  return "잘라낸 항목 \(count)개 대기"
        case .some(false): return "복사한 항목 \(count)개 대기"
        case .none:        return "복사/잘라낸 항목 \(count)개 대기"
        }
    }
}
