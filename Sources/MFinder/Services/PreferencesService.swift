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

    var sortAscending: Bool {
        get {
            // Distinguish "unset" from "false"; default to true on first launch.
            if defaults.object(forKey: kSortAscending) == nil { return true }
            return defaults.bool(forKey: kSortAscending)
        }
        set { defaults.set(newValue, forKey: kSortAscending) }
    }
}
