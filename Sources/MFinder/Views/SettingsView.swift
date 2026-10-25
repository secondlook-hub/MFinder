import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Content of the Settings scene (⌘,). Font size + theme selection + custom
/// theme management. All state lives in ThemeService.shared so every open
/// window restyles live as controls change.
struct SettingsView: View {
    @ObservedObject private var themes = ThemeService.shared
    @ObservedObject private var loc = LocalizationService.shared
    @ObservedObject private var uiState = AppUIState.shared
    @State private var importResult: String?

    /// Non-nil while the theme editor sheet is up. Carries the draft the
    /// editor starts from (a copy of an existing custom theme, or a fresh
    /// clone of the current theme for "새 테마 만들기").
    @State private var editorDraft: ThemeEditorDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ── 언어
            VStack(alignment: .leading, spacing: 6) {
                Text(L("언어")).font(.headline)
                HStack(spacing: 10) {
                    Picker(L("언어"), selection: languageSelection) {
                        ForEach(loc.availableLanguages) { lang in
                            Text(lang.menuLabel).tag(lang.rawValue)
                        }
                        if !loc.customCodes.isEmpty {
                            Divider()
                            ForEach(loc.customCodes, id: \.self) { code in
                                Text(code).tag(code)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Button(L("내보내기…")) { exportTranslations() }
                    Button(L("불러오기…")) { importTranslations() }
                }
                Text(L("번역을 JSON 파일로 내보내 편집하거나 새 언어를 추가한 뒤 다시 불러올 수 있습니다. 메뉴 막대는 앱을 다시 시작하면 반영됩니다."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if let importResult {
                    Text(importResult)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // ── 폰트 크기
            VStack(alignment: .leading, spacing: 6) {
                Text(L("폰트 크기")).font(.headline)
                HStack(spacing: 10) {
                    Slider(
                        value: $themes.fontSize,
                        in: ThemeService.fontSizeRange,
                        step: 1
                    )
                    .frame(width: 220)
                    Text("\(Int(themes.fontSize))pt")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .leading)
                    Button(L("기본값")) { themes.resetFontSize() }
                        .disabled(themes.fontSize == ThemeService.defaultFontSize)
                }
                Text(L("파일 목록·자세히 보기·사이드바 트리에 적용됩니다. (⌘= 크게 / ⌘- 작게 / ⌘0 기본)"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Toggle(L("모든 파일 확장자 표시"), isOn: $uiState.showExtensions)
                    .padding(.top, 4)
            }

            Divider()

            // ── 테마
            VStack(alignment: .leading, spacing: 6) {
                Text(L("테마")).font(.headline)
                Toggle(L("시스템 화면 모드에 맞춤 (라이트/다크 자동 전환)"), isOn: $themes.followSystemAppearance)
                Picker(L("테마"), selection: selectedThemeName) {
                    Section(L("기본 테마")) {
                        ForEach(Theme.builtins) { Text(L($0.name)).tag($0.name) }
                    }
                    if !themes.customThemes.isEmpty {
                        Section(L("내 테마")) {
                            ForEach(themes.customThemes) { Text(L($0.name)).tag($0.name) }
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(themes.followSystemAppearance)

                themePreview(themes.current)

                HStack(spacing: 8) {
                    Button(L("새 테마 만들기…")) {
                        var draft = themes.current
                        draft.name = uniqueThemeName(base: L("내 테마"))
                        editorDraft = ThemeEditorDraft(theme: draft, originalName: nil)
                    }
                    if !themes.isBuiltin(themes.current) {
                        Button(L("현재 테마 편집…")) {
                            editorDraft = ThemeEditorDraft(theme: themes.current,
                                                           originalName: themes.current.name)
                        }
                        Button(L("현재 테마 삭제")) {
                            themes.deleteCustomTheme(named: themes.current.name)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 480, height: 440, alignment: .topLeading)
        .sheet(item: $editorDraft) { draft in
            ThemeEditorView(draft: draft)
        }
    }

    // MARK: - Language

    private var languageSelection: Binding<String> {
        Binding(
            get: {
                // Show the built-in selection, or a custom imported code.
                if let stored = UserDefaults.standard.string(forKey: "mfinder.language"),
                   loc.customCodes.contains(stored) {
                    return stored
                }
                return loc.current.rawValue
            },
            set: { raw in
                if let lang = LocalizationService.Language(rawValue: raw) {
                    loc.setLanguage(lang)
                } else {
                    loc.setCustomCode(raw)
                }
            }
        )
    }

    private func exportTranslations() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MFinder-translations.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try loc.exportJSON().write(to: url, options: .atomic)
            importResult = L("내보내기 완료")
        } catch {
            importResult = L("내보내기 실패") + ": " + error.localizedDescription
        }
    }

    private func importTranslations() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let codes = try loc.importJSON(data)
            importResult = Lf("불러오기 완료 (%@)", codes.joined(separator: ", "))
        } catch {
            importResult = L("불러오기 실패") + ": " + error.localizedDescription
        }
    }

    private var selectedThemeName: Binding<String> {
        Binding(
            get: { themes.current.name },
            set: { name in
                if let t = themes.allThemes.first(where: { $0.name == name }) {
                    // A hand-picked theme overrides the follow-system mode.
                    themes.followSystemAppearance = false
                    themes.current = t
                }
            }
        )
    }

    private func uniqueThemeName(base: String) -> String {
        let taken = Set(themes.allThemes.map(\.name))
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Small swatch strip so the user sees a theme's palette at a glance.
    private func themePreview(_ theme: Theme) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(swatches(of: theme).enumerated()), id: \.offset) { _, entry in
                RoundedRectangle(cornerRadius: 3)
                    .fill(entry.1.color)
                    .frame(width: 22, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
                    .help(L(entry.0))
            }
            Text(theme.isDark ? L("다크 기반") : L("라이트 기반"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.leading, 4)
        }
    }

    private func swatches(of t: Theme) -> [(String, CodableColor)] {
        [("창 배경", t.windowBackground), ("바 배경", t.barBackground),
         ("콘텐츠 배경", t.contentBackground), ("선택 강조", t.selection),
         ("포인트 색상", t.accent), ("텍스트", t.text), ("보조 텍스트", t.secondaryText)]
    }
}

/// Sheet payload: the theme to edit plus the name it was stored under
/// (nil when creating a new one) so a rename can drop the old entry.
struct ThemeEditorDraft: Identifiable {
    var theme: Theme
    var originalName: String?
    var id: String { originalName ?? "\u{0}new" }
}

struct ThemeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themes = ThemeService.shared

    @State private var draft: Theme
    private let originalName: String?

    init(draft: ThemeEditorDraft) {
        _draft = State(initialValue: draft.theme)
        originalName = draft.originalName
    }

    private var nameError: String? {
        let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return L("이름을 입력하세요.") }
        if Theme.builtin(named: trimmed) != nil { return L("기본 테마 이름은 사용할 수 없습니다.") }
        if trimmed != originalName,
           themes.customThemes.contains(where: { $0.name == trimmed }) {
            return L("같은 이름의 테마가 이미 있습니다.")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(originalName == nil ? L("새 테마 만들기") : L("테마 편집"))
                .font(.headline)

            HStack {
                Text(L("이름")).frame(width: 90, alignment: .trailing)
                TextField(L("테마 이름"), text: $draft.name).frame(width: 200)
            }
            if let err = nameError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .padding(.leading, 98)
            }

            HStack {
                Text(L("기반 모드")).frame(width: 90, alignment: .trailing)
                Toggle(L("다크 모드 (메뉴·대화 상자 등 시스템 요소)"), isOn: $draft.isDark)
            }

            Divider()

            colorRow("창 배경",     \.windowBackground)
            colorRow("바 배경",     \.barBackground)
            colorRow("콘텐츠 배경", \.contentBackground)
            colorRow("선택 강조",   \.selection)
            colorRow("포인트 색상", \.accent)
            colorRow("텍스트",      \.text)
            colorRow("보조 텍스트", \.secondaryText)

            Divider()

            HStack {
                Spacer()
                Button(L("취소")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("저장")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameError != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func colorRow(_ label: String, _ keyPath: WritableKeyPath<Theme, CodableColor>) -> some View {
        HStack {
            Text(L(label)).frame(width: 90, alignment: .trailing)
            ColorPicker(
                L(label),
                selection: Binding(
                    get: { draft[keyPath: keyPath].color },
                    set: { draft[keyPath: keyPath] = CodableColor($0) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            Spacer()
        }
    }

    private func save() {
        var theme = draft
        theme.name = theme.name.trimmingCharacters(in: .whitespaces)
        // A rename leaves the old entry behind — drop it first.
        if let old = originalName, old != theme.name {
            themes.deleteCustomTheme(named: old)
        }
        themes.saveCustomTheme(theme)
        dismiss()
    }
}
