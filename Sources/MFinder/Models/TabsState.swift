import Foundation
import SwiftUI

@MainActor
final class TabsState: ObservableObject {
    @Published var tabs: [NavigationState]
    @Published var activeIndex: Int = 0

    init() {
        self.tabs = [NavigationState()]
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
