import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var tabs = TabsState()
    @EnvironmentObject var updateChecker: UpdateChecker

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
        .background(Color(red: 0.94, green: 0.94, blue: 0.94))
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.light)
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
        .task {
            // Auto-check GitHub Releases on launch. Silent on failure.
            await updateChecker.checkForUpdates()
        }
        .alert("업데이트 사용 가능", isPresented: $updateChecker.updateAvailable) {
            if let downloadURL = updateChecker.downloadURL {
                Button("다운로드") {
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
            Text("MFinder \(updateChecker.latestVersion) 버전이 출시되었습니다.\n(현재 버전: \(updateChecker.currentVersion))")
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

    var body: some View {
        VStack(spacing: 0) {
            AddressBar()
            CommandBar()
            HSplitView {
                SidebarView()
                    .frame(minWidth: 160, idealWidth: 240, maxWidth: 400)
                FileListView()
                    .frame(minWidth: 400)
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
