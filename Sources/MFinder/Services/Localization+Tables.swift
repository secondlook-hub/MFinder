import Foundation

/// Built-in translation tables. The Korean source string is the key; Korean
/// itself needs no entry (it is the fallback). Users can override or extend
/// these at runtime via Settings → 언어 → 내보내기/불러오기.
///
/// Keys must match the Korean strings passed to `L(...)` / `Lf(...)` exactly,
/// byte for byte (including trailing "…", spaces, and `%@`/`%d` placeholders).
enum LocalizationTables {
    static let builtin: [String: [String: String]] = [
        "en": en,
        "ja": ja,
        "zh-Hans": zhHans,
        "zh-Hant": zhHant,
        "es": es,
        "fr": fr,
        "de": de,
        "it": it,
        "pt-BR": ptBR,
        "ru": ru,
        "nl": nl,
        "pl": pl,
        "tr": tr,
        "vi": vi,
        "id": idn,
        "ar": ar,
        "hi": hi,
    ]

    // Each language dictionary is defined in Localization+Tables.generated.swift
}
