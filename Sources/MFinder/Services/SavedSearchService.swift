import Foundation
import SwiftUI

/// A saved search (smart folder): a query plus the folder it was scoped to.
struct SavedSearch: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var query: String
    var scopePath: String

    var scopeURL: URL { URL(fileURLWithPath: scopePath) }
}

/// App-wide saved searches, persisted as JSON in UserDefaults. Surfaced in
/// 이동 → 저장된 검색.
@MainActor
final class SavedSearchService: ObservableObject {
    static let shared = SavedSearchService()

    @Published private(set) var searches: [SavedSearch] = []
    private let key = "MFinder.savedSearches"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([SavedSearch].self, from: data) {
            searches = list
        }
    }

    func add(name: String, query: String, scope: URL) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !query.isEmpty else { return }
        searches.append(SavedSearch(name: trimmed, query: query, scopePath: scope.standardizedFileURL.path))
        persist()
    }

    func remove(_ search: SavedSearch) {
        searches.removeAll { $0.id == search.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(searches) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Menu content for 이동 → 저장된 검색.
struct SavedSearchesMenu: View {
    @ObservedObject private var store = SavedSearchService.shared

    var body: some View {
        if store.searches.isEmpty {
            Text(L("저장된 검색 없음"))
        } else {
            ForEach(store.searches) { s in
                Button(s.name) {
                    NotificationCenter.default.post(name: .mfinderRunSearch, object: s)
                }
            }
            Divider()
            Menu(L("삭제")) {
                ForEach(store.searches) { s in
                    Button(s.name) { store.remove(s) }
                }
            }
        }
    }
}
