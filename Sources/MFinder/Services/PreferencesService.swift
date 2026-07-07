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
    private let kGroupField    = "MFinder.groupField"
    private let kShowPreview   = "MFinder.showPreviewPane"

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

    var sortAscending: Bool {
        get {
            // Distinguish "unset" from "false"; default to true on first launch.
            if defaults.object(forKey: kSortAscending) == nil { return true }
            return defaults.bool(forKey: kSortAscending)
        }
        set { defaults.set(newValue, forKey: kSortAscending) }
    }
}
