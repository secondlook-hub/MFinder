import Foundation
import SwiftUI
import AppKit

/// App-wide localization.
///
/// Design: the Korean source string IS the lookup key. Call sites wrap
/// user-visible text in `L("한국어")` (or `Lf("…%@…", arg)` for interpolated
/// text); Korean therefore needs no table and is always the fallback when a
/// translation is missing. Translation tables for the other languages live in
/// `Localization+Tables.swift` (built-in defaults) and can be overridden /
/// extended at runtime via import (persisted to Application Support), so a
/// user can export the strings, edit or add a language, and import them back.
///
/// Runtime switching: `current` is @Published and bumps `generation`. The
/// window content subtree is tagged `.id(loc.generation)` (see ContentView),
/// so switching language rebuilds it and every `L()` call re-evaluates — no
/// relaunch needed for the window. AppKit context menus / alerts are built
/// on demand and localize the next time they open. (The top menu bar, built
/// by SwiftUI `.commands` at launch, updates after a relaunch.)
///
/// NOTE: deliberately NOT @MainActor so `L()` is callable from the few
/// nonisolated helpers (e.g. FileConflictPrompt). All writes happen on the
/// main thread during user actions; reads are plain dictionary lookups.
final class LocalizationService: ObservableObject {
    static let shared = LocalizationService()

    enum Language: String, CaseIterable, Identifiable {
        case system = "system"
        case ko
        case en
        case ja
        case zhHans = "zh-Hans"

        var id: String { rawValue }

        /// Name shown in the Settings picker (always in that language's own
        /// script, except 시스템 which follows the UI).
        var menuLabel: String {
            switch self {
            case .system: return L("시스템 언어 (자동)")
            case .ko:     return "한국어"
            case .en:     return "English"
            case .ja:     return "日本語"
            case .zhHans: return "简体中文"
            }
        }
    }

    private static let defaultsKey = "mfinder.language"

    @Published private(set) var current: Language
    /// Bumped on every effective-language change; views key `.id` off it.
    @Published private(set) var generation: Int = 0

    /// Resolved code actually used for lookups: "ko"/"en"/"ja"/"zh-Hans"
    /// (or an imported custom code). Never "system".
    private(set) var effective: String

    /// code → [korean key : translated]. "ko" has no table (identity).
    /// Seeded from the built-in defaults, then overlaid with imported overrides.
    private var tables: [String: [String: String]]

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        let lang = stored.flatMap(Language.init(rawValue:)) ?? .system
        current = lang

        // Built-in defaults, then imported overrides from Application Support.
        var merged = LocalizationTables.builtin
        if let overrides = Self.loadImportedTables() {
            for (code, dict) in overrides {
                merged[code, default: [:]].merge(dict) { _, new in new }
            }
        }
        tables = merged
        effective = Self.resolve(lang, tables: merged)
    }

    // MARK: - Lookup

    func translate(_ ko: String) -> String {
        if effective == "ko" { return ko }
        return tables[effective]?[ko] ?? ko
    }

    // MARK: - Switching

    func setLanguage(_ lang: Language) {
        guard lang != current else {
            // Re-resolve anyway (system language may have changed).
            let newEff = Self.resolve(lang, tables: tables)
            if newEff != effective { effective = newEff; generation += 1 }
            return
        }
        current = lang
        UserDefaults.standard.set(lang.rawValue, forKey: Self.defaultsKey)
        // Keep AppleLanguages aligned so AppKit/SwiftUI framework strings and
        // the top menu bar follow on next relaunch.
        applyAppleLanguages(for: lang)
        effective = Self.resolve(lang, tables: tables)
        generation += 1
    }

    /// Languages offered in the picker (built-ins). Imported custom codes are
    /// surfaced separately via `customCodes`.
    var availableLanguages: [Language] { Language.allCases }

    /// Non-built-in language codes introduced by an import (e.g. "fr", "de").
    var customCodes: [String] {
        let known = Set(["ko", "en", "ja", "zh-Hans"])
        return tables.keys.filter { !known.contains($0) }.sorted()
    }

    /// Select a raw code directly (used for imported custom languages).
    func setCustomCode(_ code: String) {
        current = .system // picker shows it separately; store the code
        UserDefaults.standard.set(code, forKey: Self.defaultsKey)
        applyAppleLanguages(code: code)
        effective = tables[code] != nil ? code : "ko"
        generation += 1
    }

    private static func resolve(_ lang: Language, tables: [String: [String: String]]) -> String {
        switch lang {
        case .ko:     return "ko"
        case .en:     return "en"
        case .ja:     return "ja"
        case .zhHans: return "zh-Hans"
        case .system:
            // Follow the OS preferred-language order; fall back to English for
            // languages we don't ship (Korean is the key, English the broadest
            // translation we provide).
            for pref in Locale.preferredLanguages {
                let code = pref.lowercased()
                if code.hasPrefix("ko") { return "ko" }
                if code.hasPrefix("ja") { return "ja" }
                if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw") || code.hasPrefix("zh-hk") {
                    // No Traditional table shipped; use Simplified if present.
                    return tables["zh-Hant"] != nil ? "zh-Hant" : "zh-Hans"
                }
                if code.hasPrefix("zh") { return "zh-Hans" }
                if code.hasPrefix("en") { return "en" }
            }
            return "en"
        }
    }

    private func applyAppleLanguages(for lang: Language) {
        switch lang {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .ko:     applyAppleLanguages(code: "ko")
        case .en:     applyAppleLanguages(code: "en")
        case .ja:     applyAppleLanguages(code: "ja")
        case .zhHans: applyAppleLanguages(code: "zh-Hans")
        }
    }

    private func applyAppleLanguages(code: String) {
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }

    // MARK: - Export / Import

    /// All translation tables (ko is implicit — exported as the key list with
    /// empty values so an editor sees every string that needs translating).
    func exportPayload() -> [String: [String: String]] {
        var out = tables
        // Include the full key universe under "ko" so an editor can see every
        // translatable string even if a given language is incomplete.
        let allKeys = Set(tables.values.flatMap { $0.keys })
        var koMap: [String: String] = [:]
        for k in allKeys { koMap[k] = k }
        out["ko"] = koMap
        return out
    }

    func exportJSON() throws -> Data {
        let payload = exportPayload()
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Merge an imported JSON ({ "en": {"키":"값"}, … }) over the current
    /// tables, persist, and refresh the live language. Returns the codes that
    /// were touched.
    @discardableResult
    func importJSON(_ data: Data) throws -> [String] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalizationError.badFormat
        }
        var touched: [String] = []
        for (code, value) in obj {
            if code == "ko" { continue } // ko is the identity/key space
            guard let dict = value as? [String: String] else { continue }
            tables[code, default: [:]].merge(dict) { _, new in new }
            touched.append(code)
        }
        try persistImportedTables()
        effective = Self.resolve(current, tables: tables)
        generation += 1
        return touched.sorted()
    }

    // MARK: - Persistence of imported overrides

    private static func supportDir() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("MFinder", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func overridesURL() -> URL? {
        supportDir()?.appendingPathComponent("translations.json")
    }

    private static func loadImportedTables() -> [String: [String: String]]? {
        guard let url = overridesURL(),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return nil }
        return obj
    }

    /// Persist only the diff vs. the built-ins so imports survive relaunch
    /// without baking the whole default set onto disk.
    private func persistImportedTables() throws {
        guard let url = Self.overridesURL() else { return }
        var diff: [String: [String: String]] = [:]
        for (code, dict) in tables {
            let base = LocalizationTables.builtin[code] ?? [:]
            var changed: [String: String] = [:]
            for (k, v) in dict where base[k] != v { changed[k] = v }
            if !changed.isEmpty { diff[code] = changed }
        }
        let data = try JSONSerialization.data(withJSONObject: diff,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

enum LocalizationError: LocalizedError {
    case badFormat
    var errorDescription: String? {
        L("번역 파일 형식이 올바르지 않습니다.")
    }
}

// MARK: - Global helpers

/// Localize a Korean source string.
func L(_ ko: String) -> String {
    LocalizationService.shared.translate(ko)
}

/// Localize a Korean format string and fill its placeholders.
/// e.g. `Lf("%d개 항목", count)` or `Lf("%@을(를) 삭제", name)`.
func Lf(_ koFormat: String, _ args: CVarArg...) -> String {
    String(format: LocalizationService.shared.translate(koFormat), arguments: args)
}
