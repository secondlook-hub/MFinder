import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var tabs = TabsState()
    @EnvironmentObject var updateChecker: UpdateChecker
    @ObservedObject private var themes = ThemeService.shared

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
                .environmentObject(tabs)

            // Reuse the tab pane across tab switches; just swap which
            // NavigationState/tree is in the environment. The NSTableView
            // detects the new nav via its dataVersion and reloads cheaply.
            TabContent(tab: tabs.active)
                .environmentObject(tabs.active)
                .environmentObject(tabs.active.tree)
                .environmentObject(tabs)
        }
        .background(themes.theme.windowBackground.color)
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(themes.theme.isDark ? .dark : .light)
        .onReceive(NotificationCenter.default.publisher(for: .mfinderNewTab)) { notif in
            if let url = notif.object as? URL {
                tabs.newTab(at: url)
            } else {
                tabs.newTab()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderCloseTab)) { _ in
            tabs.closeActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderNextTab)) { _ in
            tabs.nextTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderPrevTab)) { _ in
            tabs.prevTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderGoBack)) { _ in
            tabs.active.goBack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderGoForward)) { _ in
            tabs.active.goForward()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderGoUp)) { _ in
            tabs.active.goUp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mfinderConnectToServer)) { _ in
            ServerConnectDialog.shared.present { mountedURL in
                tabs.newTab(at: mountedURL)
            }
        }
        .task {
            // Auto-check GitHub Releases on launch. Silent on failure.
            await updateChecker.checkForUpdates()
        }
        .alert("업데이트 사용 가능", isPresented: $updateChecker.updateAvailable) {
            if let downloadURL = updateChecker.downloadURL {
                Button("자동 설치") {
                    UpdateInstaller.shared.install(from: downloadURL,
                                                   version: updateChecker.latestVersion)
                }
                Button("직접 다운로드") {
                    NSWorkspace.shared.open(downloadURL)
                }
            }
            if let releaseURL = updateChecker.releaseURL {
                Button("릴리즈 보기") {
                    NSWorkspace.shared.open(releaseURL)
                }
            }
            Button("나중에", role: .cancel) {}
        } message: {
            Text("MFinder \(updateChecker.latestVersion) 버전이 출시되었습니다.\n(현재 버전: \(updateChecker.currentVersion))\n\n자동 설치를 누르면 다운로드부터 재실행까지 자동으로 진행됩니다.")
        }
        .alert("최신 버전 사용 중", isPresented: $updateChecker.upToDate) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("MFinder \(updateChecker.currentVersion)이(가) 최신 버전입니다.")
        }
    }
}

/// The full per-tab content (command bar + address bar + sidebar/list + status bar).
private struct TabContent: View {
    @ObservedObject var tab: NavigationState
    @ObservedObject private var uiState = AppUIState.shared

    var body: some View {
        VStack(spacing: 0) {
            AddressBar()
            CommandBar()
            HSplitView {
                // Tag with the active tab's object identity so the entire
                // sidebar (NSOutlineView + Coordinator + Combine
                // subscriptions) is torn down and rebuilt against the new
                // tab's NavigationState / FolderTreeStore on tab switch.
                // Without this, the Coordinator keeps observing the
                // previous tab's nav and the tree never moves to the new
                // tab's currentURL.
                SidebarView()
                    .id(ObjectIdentifier(tab))
                    .frame(minWidth: 160, idealWidth: 240, maxWidth: 400)
                FileListView()
                    .frame(minWidth: 400)
                if uiState.showPreviewPane {
                    PreviewPane()
                        .frame(minWidth: 200, idealWidth: 300, maxWidth: 520)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBar()
        }
        .onChange(of: tab.currentURL) { newURL in
            tab.tree.ensureVisible(newURL)
            tab.tree.reloadChildren(of: newURL.deletingLastPathComponent())
        }
    }
}
