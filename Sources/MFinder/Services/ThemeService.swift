import SwiftUI
import AppKit

/// A single RGBA color that can round-trip through JSON (for custom theme
/// persistence) and convert to both SwiftUI and AppKit color types.
struct CodableColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(nsColor: nsColor) }

    /// Blend toward another color; used to derive hover/emphasized variants
    /// so themes don't need to define every micro-state.
    func blended(toward other: CodableColor, fraction f: Double) -> CodableColor {
        CodableColor(r: r + (other.r - r) * f,
                     g: g + (other.g - g) * f,
                     b: b + (other.b - b) * f,
                     a: a + (other.a - a) * f)
    }
}

/// Full color set for the app chrome + file panes. `isDark` additionally
/// switches NSAppearance/colorScheme so system-semantic colors (labels,
/// field editors, menus) follow along.
struct Theme: Codable, Equatable, Identifiable {
    var name: String
    var isDark: Bool
    var windowBackground: CodableColor   // window chrome behind panes
    var barBackground: CodableColor      // tab bar / command bar / status bar
    var contentBackground: CodableColor  // file list, sidebar, address/search fields
    var selection: CodableColor          // selected row fill
    var accent: CodableColor             // active tab underline, breadcrumb icon, 내 PC
    var text: CodableColor               // primary labels
    var secondaryText: CodableColor      // dimmed labels, chrome icons

    var id: String { name }

    /// Focused-table selection — slightly stronger than the unfocused fill.
    var selectionEmphasized: CodableColor {
        selection.blended(toward: text, fraction: 0.08)
    }
    /// Zebra-stripe companion for `contentBackground`.
    var contentBackgroundAlternate: CodableColor {
        contentBackground.blended(toward: text, fraction: 0.03)
    }

    static let light = Theme(
        name: "라이트",
        isDark: false,
        windowBackground:  CodableColor(r: 0.94, g: 0.94, b: 0.94),
        barBackground:     CodableColor(r: 0.93, g: 0.93, b: 0.93),
        contentBackground: CodableColor(r: 1.00, g: 1.00, b: 1.00),
        selection:         CodableColor(r: 0.92, g: 0.92, b: 0.92),
        accent:            CodableColor(r: 0.00, g: 0.47, b: 0.84),
        text:              CodableColor(r: 0.00, g: 0.00, b: 0.00),
        secondaryText:     CodableColor(r: 0.35, g: 0.35, b: 0.35)
    )

    static let dark = Theme(
        name: "다크",
        isDark: true,
        windowBackground:  CodableColor(r: 0.13, g: 0.13, b: 0.14),
        barBackground:     CodableColor(r: 0.16, g: 0.16, b: 0.17),
        contentBackground: CodableColor(r: 0.11, g: 0.11, b: 0.12),
        selection:         CodableColor(r: 0.26, g: 0.26, b: 0.28),
        accent:            CodableColor(r: 0.25, g: 0.60, b: 0.95),
        text:              CodableColor(r: 0.92, g: 0.92, b: 0.93),
        secondaryText:     CodableColor(r: 0.62, g: 0.62, b: 0.64)
    )

    static let builtins: [Theme] = [.light, .dark]

    static func builtin(named name: String) -> Theme? {
        builtins.first { $0.name == name }
    }
}

/// Central theme + font-size state. UserDefaults-backed; every window in the
/// process observes the shared instance, so a change in the settings window
/// restyles all open tabs immediately. (Other MFinder instances pick the
/// change up on next launch, same as PinnedFoldersService.)
@MainActor
final class ThemeService: ObservableObject {
    static let shared = ThemeService()

    static let defaultFontSize: CGFloat = 12
    static let fontSizeRange: ClosedRange<CGFloat> = 10...18

    private let defaults = UserDefaults.standard
    private let kSelectedTheme = "MFinder.theme.selected"
    private let kCustomThemes  = "MFinder.theme.custom"
    private let kFontSize      = "MFinder.fontSize"
    private let kFollowSystem  = "MFinder.theme.followSystem"

    @Published var current: Theme {
        didSet {
            defaults.set(current.name, forKey: kSelectedTheme)
            applyAppearance()
        }
    }

    /// When on, the 라이트/다크 builtin follows the macOS appearance
    /// (시스템 설정 → 화면 모드) live — the app no longer sits white in a
    /// dark desktop. Picking a theme by hand in 설정 switches this off.
    @Published var followSystemAppearance: Bool {
        didSet {
            defaults.set(followSystemAppearance, forKey: kFollowSystem)
            if followSystemAppearance { syncToSystemAppearance() }
        }
    }

    @Published private(set) var customThemes: [Theme] {
        didSet {
            if let data = try? JSONEncoder().encode(customThemes) {
                defaults.set(data, forKey: kCustomThemes)
            }
        }
    }

    /// Base font size for file names (details table, list/icon modes, sidebar
    /// tree). Secondary lines scale down from this; row heights follow it.
    @Published var fontSize: CGFloat {
        didSet { defaults.set(Double(fontSize), forKey: kFontSize) }
    }

    private init() {
        let saved = defaults.data(forKey: kCustomThemes)
            .flatMap { try? JSONDecoder().decode([Theme].self, from: $0) } ?? []
        customThemes = saved

        let selectedName = defaults.string(forKey: kSelectedTheme) ?? Theme.light.name
        current = Theme.builtin(named: selectedName)
            ?? saved.first { $0.name == selectedName }
            ?? .light

        let storedSize = defaults.double(forKey: kFontSize)
        fontSize = storedSize > 0
            ? CGFloat(storedSize).clamped(to: Self.fontSizeRange)
            : Self.defaultFontSize

        // Default ON unless the user ever picked a theme by hand (then keep
        // honoring that explicit choice until they opt back in via 설정).
        if defaults.object(forKey: kFollowSystem) != nil {
            followSystemAppearance = defaults.bool(forKey: kFollowSystem)
        } else {
            followSystemAppearance = defaults.string(forKey: kSelectedTheme) == nil
            // Persist the first-launch decision now — syncToSystemAppearance
            // below writes kSelectedTheme, which would flip the heuristic to
            // false on the next launch otherwise.
            defaults.set(followSystemAppearance, forKey: kFollowSystem)
        }

        applyAppearance()
        installSystemAppearanceObserver()
        if followSystemAppearance { syncToSystemAppearance() }
    }

    // MARK: - System appearance sync

    /// "AppleInterfaceThemeChangedNotification" fires when 시스템 설정 flips
    /// light/dark (it's a distributed notification; the queue is main).
    private func installSystemAppearanceObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                ThemeService.shared.syncToSystemAppearance()
            }
        }
    }

    /// NSApp.appearance is pinned by applyAppearance, so read the system
    /// preference directly instead of effectiveAppearance.
    private static func systemPrefersDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    private func syncToSystemAppearance() {
        guard followSystemAppearance else { return }
        let target: Theme = Self.systemPrefersDark() ? .dark : .light
        if current != target { current = target }
    }

    var allThemes: [Theme] { Theme.builtins + customThemes }

    var theme: Theme { current }

    // MARK: - Font size

    var secondaryFontSize: CGFloat { max(fontSize - 1, 9) }
    var snippetFontSize: CGFloat { max(fontSize - 2, 8) }
    var rowHeight: CGFloat { fontSize + 10 }

    func increaseFontSize() { fontSize = (fontSize + 1).clamped(to: Self.fontSizeRange) }
    func decreaseFontSize() { fontSize = (fontSize - 1).clamped(to: Self.fontSizeRange) }
    func resetFontSize()    { fontSize = Self.defaultFontSize }

    // MARK: - Custom theme CRUD

    func isBuiltin(_ theme: Theme) -> Bool {
        Theme.builtin(named: theme.name) != nil
    }

    /// Insert or replace by name. Built-in names are reserved — the caller
    /// (theme editor) blocks them, but guard here too. Selects the saved theme.
    func saveCustomTheme(_ theme: Theme) {
        guard Theme.builtin(named: theme.name) == nil else { return }
        if let idx = customThemes.firstIndex(where: { $0.name == theme.name }) {
            customThemes[idx] = theme
        } else {
            customThemes.append(theme)
        }
        followSystemAppearance = false
        current = theme
    }

    func deleteCustomTheme(named name: String) {
        customThemes.removeAll { $0.name == name }
        if current.name == name { current = .light }
    }

    // MARK: - Appearance

    /// Keep NSAppearance in sync so system-drawn chrome (menus, field
    /// editors, alerts, scroll bars) matches the theme's light/dark base.
    private func applyAppearance() {
        NSApp.appearance = NSAppearance(named: current.isDark ? .darkAqua : .aqua)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
