import SwiftUI

struct AddressBar: View {
    @EnvironmentObject var nav: NavigationState
    @State private var editing = false
    @State private var editedPath: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            navButtons
            breadcrumbOrEditor
                .frame(maxWidth: .infinity)
            searchBox
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    private var navButtons: some View {
        HStack(spacing: 1) {
            navButton(symbol: "arrow.left",      enabled: nav.canGoBack,    help: "뒤로 (⌘[)")     { nav.goBack() }
            navButton(symbol: "arrow.right",     enabled: nav.canGoForward, help: "앞으로 (⌘])")   { nav.goForward() }
            navButton(symbol: "arrow.up",        enabled: nav.canGoUp,      help: "위로 (⌘↑)")     { nav.goUp() }
            navButton(symbol: "arrow.clockwise", enabled: true,             help: "새로 고침 (⌘R)") { nav.reload() }
        }
    }

    /// Win11-style nav button: wider hit area (32×26), thin arrow icon,
    /// hover-only gray background, no circular chrome.
    private func navButton(symbol: String, enabled: Bool, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(enabled ? .primary : Color(white: 0.62))
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(NavHoverButtonStyle())
        .disabled(!enabled)
        .help(help)
    }

    private var breadcrumbOrEditor: some View {
        ZStack {
            if editing {
                TextField("경로", text: $editedPath, onCommit: commitEdit)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            } else {
                breadcrumb
            }
        }
        .frame(height: 22)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 1)
                .stroke(Color.gray.opacity(0.5), lineWidth: 0.5)
        )
        .onTapGesture {
            editedPath = nav.currentURL.path
            editing = true
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 0) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 12))
                .foregroundColor(Color(red: 0.0, green: 0.47, blue: 0.84))
                .padding(.leading, 6)
                .padding(.trailing, 4)

            ForEach(Array(nav.pathComponents.enumerated()), id: \.offset) { _, comp in
                Button {
                    nav.navigate(to: comp.url)
                } label: {
                    Text(comp.name)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 1)
            }
            Spacer()
        }
    }

    @State private var clearHover = false

    private var searchBox: some View {
        HStack(spacing: 4) {
            // Left icon: spinner while a Spotlight query is in flight,
            // magnifying glass otherwise. Makes "검색 중" visible without
            // having to look at the status bar.
            if nav.isSearching {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.45)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 12, height: 12)
            }

            TextField("\(nav.currentURL.lastPathComponent) 검색", text: $nav.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)

            // X button only when there's something to clear.
            // Clearing `searchText` triggers NavigationState.handleSearchTextChange
            // which calls stopSearch() — both cancels the running NSMetadataQuery
            // and resets isSearching, so the spinner disappears immediately.
            if !nav.searchText.isEmpty {
                Button {
                    nav.searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(clearHover ? Color(white: 0.25) : Color(white: 0.5))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { clearHover = $0 }
                .help(nav.isSearching ? "검색 취소" : "검색 지우기")
            }
        }
        .padding(.horizontal, 6)
        .frame(width: 220, height: 22)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 1)
                .stroke(nav.isSearching ? Color(red: 0.0, green: 0.47, blue: 0.84).opacity(0.6) : Color.gray.opacity(0.5),
                        lineWidth: nav.isSearching ? 1 : 0.5)
        )
    }

    private func commitEdit() {
        let url = URL(fileURLWithPath: (editedPath as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            nav.navigate(to: url)
        }
        editing = false
    }
}

/// Subtle hover/press background used by the nav buttons. Each button owns
/// its own hover state inside the style so the @State works in isolation.
private struct NavHoverButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        configuration.isPressed ? Color.gray.opacity(0.28)
                        : hovering              ? Color.gray.opacity(0.15)
                        : Color.clear
                    )
            )
            .onHover { hovering = $0 }
    }
}
