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
        case zhHant = "zh-Hant"
        case es
        case fr
        case de
        case it
        case ptBR = "pt-BR"
        case ru
        case nl
        case pl
        case tr
        case vi
        case ind = "id"
        case ar
        case hi

        var id: String { rawValue }

        /// Name shown in the Settings picker — each language in its own script,
        /// except 시스템 which follows the current UI language.
        var menuLabel: String {
            if self == .system { return L("시스템 언어 (자동)") }
            return Self.nativeNames[rawValue] ?? rawValue
        }

        /// Native display names, keyed by language code.
        static let nativeNames: [String: String] = [
            "ko": "한국어",
            "en": "English",
            "ja": "日本語",
            "zh-Hans": "简体中文",
            "zh-Hant": "繁體中文",
            "es": "Español",
            "fr": "Français",
            "de": "Deutsch",
            "it": "Italiano",
            "pt-BR": "Português (Brasil)",
            "ru": "Русский",
            "nl": "Nederlands",
            "pl": "Polski",
            "tr": "Türkçe",
            "vi": "Tiếng Việt",
            "id": "Bahasa Indonesia",
            "ar": "العربية",
            "hi": "हिन्दी",
        ]
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

    /// Non-built-in language codes introduced by an import (shown separately
    /// in the picker). Built-in codes are covered by the Language enum.
    var customCodes: [String] {
        let known = Set(Language.allCases.map(\.rawValue))
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
        guard lang == .system else { return lang.rawValue }
        // Follow the OS preferred-language order; fall back to English for
        // languages we don't ship (Korean is the key, English the broadest
        // translation we provide).
        let shipped = Set(tables.keys).union(["ko", "en"])
        for pref in Locale.preferredLanguages {
            let code = pref.lowercased()
            if code.hasPrefix("zh") {
                if code.contains("hant") || code.contains("-tw") || code.contains("-hk") || code.contains("-mo") {
                    if shipped.contains("zh-Hant") { return "zh-Hant" }
                }
                if shipped.contains("zh-Hans") { return "zh-Hans" }
                if shipped.contains("zh-Hant") { return "zh-Hant" }
            }
            if code.hasPrefix("pt"), shipped.contains("pt-BR") { return "pt-BR" }
            // Primary subtag (e.g. "en-US" → "en").
            let primary = String(code.prefix(while: { $0 != "-" }))
            if shipped.contains(primary) { return primary }
        }
        return "en"
    }

    private func applyAppleLanguages(for lang: Language) {
        if lang == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            applyAppleLanguages(code: lang.rawValue)
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
