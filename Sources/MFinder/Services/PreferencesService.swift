import Foundation

/// UserDefaults-backed persistence for window-level settings that should survive
/// quit/relaunch.
final class PreferencesService {
    static let shared = PreferencesService()

    private let defaults = UserDefaults.standard
    private let kShowHidden    = "MFinder.showHidden"
    private let kViewMode      = "MFinder.viewMode"
    private let kSortField     = "MFinder.sortField"
    private let kSortAscending = "MFinder.sortAscending"
    private let kDetailColumns = "MFinder.detailColumns"
    private let kColumnOrder   = "MFinder.detailColumnOrder"
    private let kColumnWidths  = "MFinder.detailColumnWidths"
    private let kGroupField    = "MFinder.groupField"
    private let kShowPreview   = "MFinder.showPreviewPane"
    private let kSidebarWidth  = "MFinder.sidebarWidth"

    var showHidden: Bool {
        get { defaults.bool(forKey: kShowHidden) }
        set { defaults.set(newValue, forKey: kShowHidden) }
    }

    var viewMode: ViewMode {
        get {
            let raw = defaults.string(forKey: kViewMode) ?? ViewMode.details.rawValue
            return ViewMode(rawValue: raw) ?? .details
        }
        set { defaults.set(newValue.rawValue, forKey: kViewMode) }
    }

    var sortField: SortField {
        get {
            let raw = defaults.string(forKey: kSortField) ?? SortField.name.rawValue
            return SortField(rawValue: raw) ?? .name
        }
        set { defaults.set(newValue.rawValue, forKey: kSortField) }
    }

    /// Column ids visible in the details view besides the always-on "name"
    /// (Explorer-style header right-click toggles). Newly added optional
    /// columns ("created", "extension") stay hidden until enabled.
    var detailColumns: [String] {
        get { defaults.stringArray(forKey: kDetailColumns) ?? ["modified", "type", "size"] }
        set { defaults.set(newValue, forKey: kDetailColumns) }
    }

    /// Header-drag order of the details columns, as column ids left-to-right.
    /// Includes hidden columns so toggling one back on restores its slot.
    /// Empty until the user first reorders anything.
    var detailColumnOrder: [String] {
        get { defaults.stringArray(forKey: kColumnOrder) ?? [] }
        set { defaults.set(newValue, forKey: kColumnOrder) }
    }

    /// User-dragged column widths, keyed by column id. Ids absent from the
    /// dictionary fall back to the built-in default width.
    var detailColumnWidths: [String: Double] {
        get { defaults.dictionary(forKey: kColumnWidths) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: kColumnWidths) }
    }

    var groupField: GroupField {
        get {
            let raw = defaults.string(forKey: kGroupField) ?? GroupField.none.rawValue
            return GroupField(rawValue: raw) ?? .none
        }
        set { defaults.set(newValue.rawValue, forKey: kGroupField) }
    }

    var showPreviewPane: Bool {
        get { defaults.bool(forKey: kShowPreview) }
        set { defaults.set(newValue, forKey: kShowPreview) }
    }

    /// Width of the sidebar tree pane. 0 (unset) means "use the default".
    var sidebarWidth: Double {
        get {
            let stored = defaults.double(forKey: kSidebarWidth)
            return stored > 0 ? stored : 240
        }
        set { defaults.set(newValue, forKey: kSidebarWidth) }
    }

    var sortAscending: Bool {
        get {
            // Distinguish "unset" from "false"; default to true on first launch.
            if defaults.object(forKey: kSortAscending) == nil { return true }
            return defaults.bool(forKey: kSortAscending)
        }
        set { defaults.set(newValue, forKey: kSortAscending) }
    }
}
