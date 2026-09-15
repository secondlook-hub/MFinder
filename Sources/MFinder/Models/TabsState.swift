import Foundation
import SwiftUI
import Combine

/// Detects whether *this* process was spawned as an additional MFinder window
/// (File → 새 창 / Dock → 새 창 열기). `launchNewMFinderInstance()` passes the
/// `--fresh` argument so those windows start at Home rather than restoring the
/// previous session's tabs — only the primary launch restores.
enum MFinderLaunch {
    static let isFreshInstance = CommandLine.arguments.contains("--fresh")
}

@MainActor
final class TabsState: ObservableObject {
    @Published var tabs: [NavigationState] {
        didSet { observeTabs() }
    }
    @Published var activeIndex: Int = 0 {
        didSet { persist() }
    }

    /// Per-tab `currentURL` subscriptions so a navigation inside any tab
    /// re-persists the open-tab set. Rebuilt whenever `tabs` changes.
    private var tabCancellables: [AnyCancellable] = []

    /// - Parameter restore: when true, reopen the tabs persisted from the last
    ///   session instead of starting with a single Home tab. Callers pass
    ///   `!MFinderLaunch.isFreshInstance` so only the primary window restores.
    init(restore: Bool = false) {
        if restore {
            let restored = Self.restoreTabs()
            if !restored.isEmpty {
                self.tabs = restored
                self.activeIndex = min(max(0, PreferencesService.shared.activeTabIndex), restored.count - 1)
            } else {
                self.tabs = [NavigationState()]
            }
        } else {
            self.tabs = [NavigationState()]
        }
        // didSet doesn't fire for assignments in init; wire up observation and
        // record the current state (a no-op re-save for a restored session).
        observeTabs()
    }

    /// Builds NavigationStates from the persisted paths, dropping any that no
    /// longer point at an existing directory (an ejected volume, a deleted or
    /// renamed folder).
    private static func restoreTabs() -> [NavigationState] {
        PreferencesService.shared.openTabPaths.compactMap { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return NavigationState(startingURL: URL(fileURLWithPath: path))
        }
    }

    private func observeTabs() {
        tabCancellables = tabs.map { tab in
            tab.$currentURL
                .dropFirst()
                .sink { [weak self] _ in
                    // @Published emits in `willSet`, so the tab's `currentURL`
                    // has NOT been updated yet at this point — reading it here
                    // would persist the *previous* folder (the tab reopens one
                    // step back on relaunch). Defer to the next tick so the new
                    // value has settled before persist() reads it.
                    DispatchQueue.main.async { self?.persist() }
                }
        }
        persist()
    }

    private func persist() {
        guard !tabs.isEmpty else { return }
        PreferencesService.shared.openTabPaths = tabs.map { $0.currentURL.path }
        PreferencesService.shared.activeTabIndex = min(max(0, activeIndex), tabs.count - 1)
    }

    var active: NavigationState {
        if tabs.isEmpty { tabs = [NavigationState()] }
        return tabs[min(activeIndex, tabs.count - 1)]
    }

    func newTab(at url: URL? = nil) {
        let start = url ?? active.currentURL
        let nav = NavigationState(startingURL: start)
        tabs.append(nav)
        activeIndex = tabs.count - 1
    }

    func duplicateTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let nav = NavigationState(startingURL: tabs[index].currentURL)
        tabs.insert(nav, at: index + 1)
        activeIndex = index + 1
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1, index >= 0, index < tabs.count else { return }
        tabs.remove(at: index)
        if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        } else if activeIndex > index {
            activeIndex -= 1
        }
    }

    func closeActive() {
        closeTab(at: activeIndex)
    }

    func closeOtherTabs(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let keep = tabs[index]
        tabs = [keep]
        activeIndex = 0
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeIndex = index
    }

    func nextTab() {
        guard !tabs.isEmpty else { return }
        activeIndex = (activeIndex + 1) % tabs.count
    }

    func prevTab() {
        guard !tabs.isEmpty else { return }
        activeIndex = (activeIndex - 1 + tabs.count) % tabs.count
    }
}
