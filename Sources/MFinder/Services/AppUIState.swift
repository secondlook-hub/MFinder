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

    private init() {
        showPreviewPane = PreferencesService.shared.showPreviewPane
    }
}
