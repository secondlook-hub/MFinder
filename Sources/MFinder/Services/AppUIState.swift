import Foundation
import SwiftUI

/// App-wide UI toggles that live outside any single tab (unlike
/// NavigationState) and outside theming (unlike ThemeService).
@MainActor
final class AppUIState: ObservableObject {
    static let shared = AppUIState()

    @Published var showPreviewPane: Bool {
        didSet { PreferencesService.shared.showPreviewPane = showPreviewPane }
    }

    /// Sidebar pane width. Owned here rather than left to HSplitView's
    /// implicit state: the sidebar is tagged `.id(ObjectIdentifier(tab))`, so
    /// any rebuild (tab switch, theme flip on re-activation) hands AppKit a
    /// brand-new subview and the dragged width is silently lost.
    @Published var sidebarWidth: CGFloat {
        didSet { PreferencesService.shared.sidebarWidth = Double(sidebarWidth) }
    }

    static let minSidebarWidth: CGFloat = 160
    static let maxSidebarWidth: CGFloat = 400

    private init() {
        showPreviewPane = PreferencesService.shared.showPreviewPane
        let saved = CGFloat(PreferencesService.shared.sidebarWidth)
        sidebarWidth = min(max(saved, Self.minSidebarWidth), Self.maxSidebarWidth)
    }
}
