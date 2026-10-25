# MFinder — Working Notes

A skim-first orientation for future sessions. Code is the source of truth — this file captures the things that aren't obvious from reading source: conventions, gotchas, and the release flow.

## Project shape

- Native macOS Windows-Explorer-style file manager. SwiftUI shell with AppKit views in the spots where SwiftUI's NSTextField/focus model is unreliable (sidebar tree, details file table).
- Multilingual UI — 17 languages (ko default + en, ja, zh-Hans, zh-Hant, es, fr, de, it, pt-BR, ru, nl, pl, tr, vi, id, ar, hi), switchable at runtime in 설정 → 언어. Korean is the source language and the lookup key everywhere. Sidebar sections: **즐겨찾기 / 내 PC / 네트워크**.
- Repo: `github.com/secondlook-hub/MFinder` (public). `gh` CLI is authenticated for that org.
- Min macOS 13. Swift 5.9. Single executable target via Package.swift.

## Build & release flow

```bash
./build.sh release             # → MFinder.app at repo root
scripts/makeDmg.sh             # → MFinder-v{X}.dmg + MFinder.dmg (Applications symlink)
```

### Releasing v{X.Y}

1. `Resources/Info.plist` — bump `CFBundleVersion` + `CFBundleShortVersionString` (always change both).
2. `README.md` — extend Features list if user-visible.
3. Commit: `git commit -m "<subject> (v{X.Y})"` with HEREDOC body. Push: `git push`.
4. `osascript -e 'tell application "MFinder" to quit'` (running MFinder holds the old binary), `./build.sh release`, `scripts/makeDmg.sh`.
5. `gh release create v{X.Y} MFinder-v{X.Y}.dmg MFinder.dmg --title "MFinder v{X.Y}" --notes "..."`.
6. `open https://github.com/secondlook-hub/MFinder/releases/tag/v{X.Y}` to show the user.

The in-app updater (Help → "업데이트 확인…") fetches the latest release via the GitHub API. It prefers an asset literally named `MFinder.dmg` (the stable alias), otherwise the first `.dmg`. Existing users get a Download alert on next launch.

### Commit / release-notes style

- Subject ends with ` (v{X.Y})` in the commit, not in PR titles. HEREDOC body explains *why*.
- Release notes use plain markdown headers like `## What's New`. Korean for menu/feature labels, English for narrative.

## Architecture cheat sheet

```
Sources/MFinder/
├── MFinderApp.swift        App entry, menu commands, AppDelegate.
│                           Global NSEvent.addLocalMonitorForEvents for
│                           F2/Space/⌫/⌘⌫/⌘⇧⌫/⌥⌘⌫ and (sidebar-only)
│                           ⌘C/⌘X/⌘V. applicationDockMenu adds "새 창 열기".
│                           launchNewMFinderInstance() spawns a new process
│                           via NSWorkspace.openApplication(... configuration
│                           with createsNewApplicationInstance = true).
├── ContentView.swift       Tabs root. ⚠ SidebarView is tagged
│                           `.id(ObjectIdentifier(tab))` so it rebuilds when
│                           the active tab changes (the Coordinator's Combine
│                           subscriptions are scoped to one nav/tree instance).
│                           Hosts the update-checker alert.
├── Models/
│   ├── NavigationState.swift   Per-tab. Notable fields:
│   │     - pendingSelection: Set<URL>? — sticky across reload generations
│   │       so an FSEvent-triggered reload arriving right after a paste
│   │       still applies the original `thenSelect:` set. Cleared on
│   │       navigate/back/forward.
│   │     - sidebarSelectionURLs: [URL] — published mirror of NSOutlineView
│   │       multi-selection. Sidebar Cmd+C/X/⌘⌫ handlers read this; falls
│   │       back to currentURL when empty.
│   │     - reload(thenSelect:) uses loadGeneration to cancel obsolete
│   │       async reloads; the FSEvent watcher skips while renamingURL set.
│   ├── TabsState.swift              Tab collection.
│   ├── FolderTreeStore.swift        Per-tab. expandedURLs + childrenCache.
│   │                                ensureVisible(_:) walks ancestors;
│   │                                loadChildren is sync (cheap FS read).
│   └── FileItem.swift
├── Services/
│   ├── ClipboardService.swift    Singleton, in-process. Stack semantics
│   │     (cut/copy accumulate; ⌘V drains). hasContent also queries
│   │     NSPasteboard so a fresh second instance can paste. didBecomeActive
│   │     bumps pasteboardSnapshot (@Published) so SwiftUI re-evaluates.
│   ├── ArchiveService.swift      Detects unrar/unar/7z/tar/etc. at standard
│   │     Homebrew paths. bandizipAppURL resolved via bundle id
│   │     com.bandisoft.mac.bandizip. RAR/7z fall back to
│   │     openWithBandizip(_:) when no CLI is installed.
│   ├── FileSystemWatcher.swift   kqueue vnode source per watched dir.
│   ├── FileSystemService.swift   list/quickAccessLocations/thisPCLocations/
│   │                              moveToTrash (AppleScript Finder).
│   ├── PinnedFoldersService.swift  UserDefaults; @Published pinnedURLs.
│   ├── ThemeService.swift        @MainActor singleton. Theme (Codable color
│   │     set + isDark) with 라이트/다크 builtins + custom themes persisted
│   │     as JSON in UserDefaults. fontSize (10–18, base for file panes;
│   │     rowHeight/secondary/snippet derive from it). Setting `current`
│   │     flips NSApp.appearance. AppKit views read ThemeService.shared
│   │     during cell config; representables observe it so updateNSView
│   │     reloads on change (FileTableView tracks lastTheme/lastFontSize,
│   │     sidebar Coordinator tracks syncedTheme/syncedFontSize — sidebar
│   │     skips restyle while a rename is active).
│   ├── LocalizationService.swift Runtime i18n. L()/Lf() global fns look up
│   │     the Korean source string in the current language's table
│   │     (Localization+Tables[.generated].swift); Korean is the fallback.
│   │     @Published current/generation; export/import JSON via 설정 → 언어.
│   ├── UpdateChecker.swift       GitHub Releases poll, semver compare.
│   ├── FileOperationService.swift  Background copy/move engine + Explorer-style
│   │     progress NSPanel (item name, N/M, byte-fraction bar, cancel; panel
│   │     appears only past 0.4s). Same-volume move = instant rename; cross-
│   │     volume falls back to stream-copy (4MB chunks) + delete. All paste
│   │     and drag-drop paths route through perform(_:title:completion:).
│   ├── UndoService.swift         App-wide file-op undo/redo stacks (⌘Z/⇧⌘Z,
│   │     max 50). UndoAction: move/create/trash/batch. Trash restore is
│   │     best-effort from ~/.Trash by name. Views register after success.
│   ├── UpdateInstaller.swift     "자동 설치": download DMG → hdiutil attach
│   │     → ditto to staging → detach → swap Bundle.main.bundleURL → relaunch
│   │     (createsNewApplicationInstance) → terminate old process.
│   ├── AppUIState.swift          Observable app-wide UI toggles (preview pane).
│   └── (PreferencesService, SearchSnippetService, QuickLookCoordinator)
└── Views/
    ├── SidebarView.swift             Thin SwiftUI host: SidebarOutlineRepresentable
    │                                 + .onReceive notification handlers for
    │                                 sidebar-scoped Cmd+C/X/V/⌘⌫/F2.
    ├── SidebarOutlineView.swift      NSOutlineView wrapper for the ENTIRE
    │                                 sidebar (즐겨찾기 + 내 PC + 네트워크 +
    │                                 recursive folder children, single model:
    │                                 enum SidebarItem). Inline rename via
    │                                 outline.editColumn — same path
    │                                 FileTableView uses. Click-and-pause
    │                                 rename + mouse-leave-cancel via local
    │                                 NSEvent monitor.
    ├── FileTableView.swift           Details view, native NSTableView.
    │                                 Inline rename via editColumn. selection
    │                                 sync scrolls first row into view AND
    │                                 takes first-responder (unless a text
    │                                 editor is currently focused).
    ├── FileListView.swift            Icons/list/tile/content SwiftUI modes.
    ├── RenameTextField.swift         NSViewRepresentable for the non-details
    │                                 file list modes only. FocusSeizingTextField
    │                                 subclass with retry + currentEvent-gated
    │                                 resignFirstResponder. **Sidebar does NOT
    │                                 use this** — it failed with SwiftUI
    │                                 gesture races. Also home of EditFocusWatcher
    │                                 (ends any inline rename when the app
    │                                 deactivates or the window loses key; used
    │                                 by this field + FileTableView + sidebar).
    ├── SettingsView.swift            Settings scene content (⌘,): font-size
    │                                 slider, theme picker, custom-theme editor
    │                                 sheet (ThemeEditorView).
    └── AddressBar / CommandBar / TabBar / StatusBar / ClipboardStackView
```

## Patterns to follow

### Adding user-facing strings (i18n)
Wrap every new Korean UI literal in `L("…")` (or `Lf("…%@…", arg)` for interpolation — pass args stringified: `Lf("%@개", "\(n)")`). If the string goes through a choke point that already calls `L()` internally (menu `block`/`blockItem`, `col.title`, the alert helpers, `FileOperationService.perform(title:)`, `navButton`/`iconButton` help, `keyField`/`valueField`, `colorRow`), just pass the raw Korean key — don't double-wrap. For enum `rawValue`s / theme names used as identity, keep the stored value Korean and localize only at the display site (`L(x.rawValue)`). Then add the Korean key + en/ja/zh-Hans to `Localization+Tables.generated.swift` (or rely on 설정 → 언어 → 불러오기 to patch at runtime). Keys are **runtime** strings (real newlines/quotes), matching the `L()` argument exactly.

### Adding sidebar tree actions
Use `Coordinator.actionURLs(for: clickedURL)` to get the operative URL set:
- If the right-clicked row is part of a multi-selection → returns the whole selection
- Otherwise → just the clicked row

Multi-aware menu items already use this: 복사, 잘라내기, 휴지통으로 이동, 즐겨찾기, Finder에서 보기, 경로 복사, 새로 고침, 바로 가기 만들기. Append "(N개)" to the label when N>1.

Single-only by design: 이름 바꾸기, 붙여넣기 (이 폴더 안으로), 접기/확장, 새 탭/창에서 열기, 꺼내기.

### Adding sidebar keyboard shortcuts
1. `AppDelegate` global key monitor in `MFinderApp.swift` intercepts the key, posts a `Notification`.
2. `SidebarView` adds `.onReceive(...)` handler guarded by `AppFocus.area == .sidebar`.
3. Handler reads `nav.sidebarSelectionURLs` (fallback to `[nav.currentURL]`).

### Adding file-list keyboard shortcuts
Same global key monitor; the file list's handler guards with `AppFocus.area == .fileList`. NSTableView responder methods (`@objc func cut/copy/paste`) on `FileNSTableView` are also wired through the responder chain for menu dispatch.

### `AppFocus` set points
- `.sidebar` — sidebar selection change, right-click "이름 바꾸기".
- `.fileList` — NSTableView selection change, file-list click handlers, file-table selection change.

### Cross-instance state
- ClipboardService is per-process. Cross-instance paste works because we also write the system pasteboard on copy/cut and read it on paste/hasContent. There is no cross-instance cut semantics (always behaves as copy across processes).
- PinnedFoldersService persists via UserDefaults — synced on next launch of other instances, not realtime.

### NSWorkspace notifications
Use `NSWorkspace.shared.notificationCenter` (the workspace's own center), NOT `NotificationCenter.default`. The sidebar listens for `didMount`/`didUnmount` to refresh 내 PC.

### Multi-instance launch
Always call the helper `launchNewMFinderInstance()` which sets `createsNewApplicationInstance = true`. Without it, NSWorkspace just activates the existing instance.

### Bridging @objc → @MainActor
Wrap the body in `MainActor.assumeIsolated { ... }`. Used by the Dock menu action handler and Timer closures (e.g., the click-rename timer).

## Known gotchas

- **The user runs /Applications/MFinder.app, not the repo bundle.** When smoke-testing a change, quit MFinder, build, `ditto ./MFinder.app /Applications/MFinder.app`, THEN `open /Applications/MFinder.app`. Just `open ./MFinder.app` leaves the Dock launching the stale installed copy — "the fix doesn't work" reports follow.
- **`.onTapGesture` consumes events** before child NSViews see them. That's why the sidebar tree had to move from SwiftUI rows to NSOutlineView — the inline NSTextField rename kept losing focus to the row's gesture recognizer. If you ever wrap an editable NSView in a SwiftUI view with gestures, the gestures will fight focus.
- **Reload race after paste**: `NavigationState.reload` uses `loadGeneration` to cancel obsolete reloads, but the `thenSelect:` target lives outside the closure (`pendingSelection`) so a cancelled reload doesn't lose the selection — the next successful reload reapplies it.
- **Window must accept mouse-moved events** for the sidebar's click-and-pause rename cancel-on-leave: `ov.window?.acceptsMouseMovedEvents = true` is set in `handleMouseDown`.
- **`controlTextDidEndEditing` fires on view teardown**, not just user dismissal. `RenameTextField.Coordinator` guards with `if tf.window == nil { return }` so a SwiftUI re-render-tear-down doesn't accidentally commit/cancel.
- **Unicode filename normalization has two traps**, both verified empirically (v1.22):
  1. **Swift `String ==` is canonical equivalence.** An NFD string equals its NFC form, so `name != name.precomposedStringWithCanonicalMapping` is *always false*. Detecting the difference requires comparing UTF-8 bytes. The same applies to `URL ==`, `URL.path ==`, `standardizedFileURL ==`, and `Set<URL>` — those comparisons are already normalization-proof, so don't "fix" them.
  2. **Every `FileManager` write API decomposes.** `createDirectory(at:)`, `createDirectory(atPath:)`, and `moveItem` store NFD no matter what you hand them; `URL` itself decomposes any path it holds. Only raw POSIX (`mkdir`, `rename`) on explicit UTF-8 bytes preserves NFC. `FilenameNormalization.apply` therefore uses `rename(2)`, and `UndoAction.renameBytes` carries raw path strings — routing those pairs through `URL` would erase the very distinction being restored, and `.move`'s FileManager-based undo would silently no-op.
  Reading is fine: `contentsOfDirectory(atPath:)` and `enumerator(atPath:)` return stored bytes; their URL-based counterparts do not. Test assertions must compare `Array(name.utf8)`, never `==` — a byte-blind test passes no matter what the code does. Scratchpad harness pattern: compile `FilenameNormalization.swift` + a `main.swift` and exercise plan/apply/undo on a real temp tree.
- **`NSPasteboard` doesn't have a change notification** — `ClipboardService` snapshots `changeCount` on `NSApplication.didBecomeActive` to refresh published state.

## Version history (one line)

- v1.31 — 컬럼(열) 보기 + 갤러리 보기 + 진행 속도/ETA + 휴지통 접근. ① `ViewMode`에 `.columns`/`.gallery` 추가(`iconSize`/`symbol` 분기, 뷰 모드 피커 자동 노출). `ColumnsBrowserView`(Miller 컬럼: `@State columns:[URL]` 경로, 폴더 선택 시 우측 컬럼 추가, 파일 선택 시 말단 QuickLook 컬럼; 더블클릭 폴더=`nav.navigate`; 외부 네비게이션이 컬럼 경로 밖이면 reset). `GalleryView`(상단 `QuickLookPreview` + 하단 썸네일 필름스트립, 선택 동기화). `PreviewPane`의 QL 래퍼를 `QuickLookPreview`(internal)로 공개해 재사용. **함정**: ViewMode에 케이스 추가 시 CommandBar의 `viewModeSymbol` 같은 switch가 비망라가 됨 → `nav.viewMode.symbol`로 위임해 중복 제거. ② `FileProgressPanel`에 `detailLabel` 추가, `setStats(fraction:totalBytes:start:)`로 속도(ByteCountFormatter)·ETA 계산(elapsed>0.5s 가드); `perform`이 시작시각 캡처해 진행 콜백에서 호출. ③ 휴지통: `quickAccessLocations()`에 `~/.Trash` 항목 추가(기존 네비게이션 재사용, 숨김 가능). 새 키는 scratchpad 스크립트로 17개 언어 삽입(ETA 5개 + 모드명 2개 + "휴지통").
- v1.30 — Finder/Explorer 갭 메우기 1차 + 번역 보강. ① 콘텐츠 썸네일: `ThumbnailService`(QLThumbnailGenerator + NSCache, 키에 mtime 포함). `IconView(item:size:)`가 ≥24pt일 때 비동기 요청→도착 시 `@State thumb` 교체; **온라인 전용(`cloudState==.notDownloaded`)·디렉터리는 제외**(썸네일 생성이 다운로드를 유발하므로). details(16pt)는 타입 아이콘 유지. Package.swift에 `QuickLookThumbnailing` 링크. ② 충돌 "둘 다 유지": `FileConflictChoice.keepBoth` 추가 → paste/3개 드롭 핸들러 모두 unique 이름으로 복사(기존 항목 보존). ③ 복제/④ 선택 항목으로 새 폴더: FileTableView·FileListView 우클릭 + 메서드(FileOperationService.perform, batch undo). ⑤ 태그 색상: `FileItem.labelColor`(`.labelColorKey`, 없고 태그만 있으면 systemGray) — 리스트 조회 때 같이 읽음(stat 추가 없음); SwiftUI는 IconView 코너 오버레이, details는 `iconWithTagDot`로 아이콘에 점 합성(이름 편집과 안 충돌). ⑥ **번역 누락 100건 수정**: block/blockItem·알럿 헬퍼·perform(title:) 등 초크 포인트에 L() 없이 넘어가던 리터럴은 런타임엔 번역되지만 **테이블엔 없어** 다른 언어에서 한국어로 보였음(v1.28/v1.29 회귀). 전체 한국어 리터럴을 추출해 17개 언어로 채움 → 420개 런타임 문자열 100% 커버. **교훈**: 번역 키 추출은 `L(/Lf(` 리터럴뿐 아니라 **초크 포인트로 들어가는 리터럴·enum rawValue**까지 포함해야 함(scratchpad에 "모든 한국어 리터럴 ⊆ en 테이블" 검증 스크립트).
- v1.29 — 언어 14종 추가(총 17종): zh-Hant/es/fr/de/it/pt-BR/ru/nl/pl/tr/vi/id/ar/hi. `Language` enum을 코드 기반으로 확장(`nativeNames` 딕셔너리 + `resolve`를 모든 코드로 일반화, `zh-Hant`/`pt-BR` 시스템 매칭 변형 처리), 피커가 전 언어 네이티브 이름으로 노출. 번역은 언어당 서브에이전트 1개로 병렬 생성(ko+en 피벗 `scratchpad/pivot.json` → `tr_<code>.json`), 병합 시 **플레이스홀더(`%@`/`%d`) 개수 무결성**을 ko 원문 대비 검증해 불일치는 영어로 안전 폴백(결과: 전 언어 0건). `Localization+Tables.swift` builtin에 17개 코드 등록, Info.plist `CFBundleLocalizations`/build.sh `.lproj`도 동일. **함정**: 생성 테이블 재추출 시 dict 경계를 `]`로 자르면 `[String: String]`의 `]`에 걸려 비는데(zh-Hans 0건 사고), `static let X … = [ … \n    ]` 블록 정규식으로 잘라야 함 — en/ja/zh-Hans 원본은 깨진 작업본 대신 `git show HEAD:`에서 가져와 복구.
- v1.28 — 다국어(한/영/일/중) + 삭제 아이콘·단축키. ① `LocalizationService`(Services) — Korean 원문이 곧 조회 키. `L("…")`/`Lf("…%@…", arg)` 전역 함수가 현재 언어 테이블에서 번역을 찾고, 없으면 Korean 폴백. 기본 번역은 `Localization+Tables.generated.swift`에 임베드(SPM 리소스 번들 대신 소스 임베드 — build.sh가 커스텀이라 번들 경로 리스크 회피). 설정 → 언어에서 즉시 전환: `current` 변경이 `generation`을 올리고 ContentView가 `.id(loc.generation)`로 창 내용을 재생성 → 모든 `L()` 재평가(재시작 불필요). 컨텍스트 메뉴/알럿은 on-demand라 다음에 열 때 반영. **메뉴 막대(SwiftUI `.commands`)만 재시작 후 반영**(+ `AppleLanguages`로 AppKit 프레임워크 문자열도 재시작 시 따라옴; Info.plist `CFBundleLocalizations`/build.sh가 ko/en/ja/zh-Hans `.lproj` 생성). **수정 범위 최소화 비결**: `block`/`blockItem`(메뉴), `col.title`, 알럿 헬퍼(`showSimpleAlert`/`showTreeAlert`/`commandAlert`/`alertError`/`presentAlert`/`showError`/`reportFailure`), `FileOperationService.perform(title:)`, `navButton`/`iconButton`(help), `keyField`/`valueField`, `colorRow`가 **내부에서 L()** 하므로 호출부는 Korean 키만 넘기면 됨(수정 불필요). 보간 문자열은 `Lf` + `%@`(모든 인자를 `"\(expr)"`로 문자열화 → 타입 무관 안전). enum rawValue(ViewMode/SortColumn/SidebarSection)·테마 이름은 **키로 유지**하고 표시부에서 `L(rawValue)` — 영속성/비교가 rawValue·path 기준이라 깨지지 않음(핀/숨김은 `hiddenBuiltinPaths` 경로 기준). export/import: 설정에서 번역 전체를 JSON으로 내보내/불러오기(Application Support에 override 영속, 새 언어 코드 추가 가능). ② 우클릭 "휴지통으로 이동"에 `trash` SF Symbol + `⌘D`(Windows Ctrl+D 대응, AppDelegate 전역 모니터가 `.mfinderTrashSelected` 포커스 라우팅; 기존 `⌫`도 유지), "영구 삭제"는 `trash.slash`. **함정**: 번역 키는 **런타임 문자열**(실제 개행·따옴표)이어야 L 인자와 매칭 — 생성기가 `\n`/`\"`를 Swift 소스용으로 이스케이프. 키 집합 검증은 scratchpad에 `keys` 추출 + 생성 테이블 대조 스크립트(소스 `L/Lf` 리터럴 ⊆ en 테이블).
- v1.27 — 탭에 파일 드롭. `TabBar.swift`의 각 `TabCell`에 `TabDropDelegate: DropDelegate` 추가 — 드롭하면 그 탭의 `nav.currentURL` 폴더로 이동(기본)/복사(⌥), 비활성 탭 위 0.6초 dwell 시 `activate()`로 스프링 로드 전환. 충돌 프롬프트(`askFileConflict`)·자기-폴더 가드·`FileOperationService.perform`·`UndoService.register`·refresh는 사이드바 `acceptDrop`과 동일 로직을 `performTabDrop(urls:into:copy:)`로 복제(@MainActor). `NSItemProvider.loadObject(ofClass: NSURL.self)`로 드롭 순서 보존해 URL 수집. DropDelegate 메서드는 nonisolated이므로 main-큐 완료 콜백에서 `MainActor.assumeIsolated`로 진입.
- v1.26 — 탭 세션 복원 + 압축/압축 풀기 우클릭 승격 + 마우스 앞/뒤 버튼 신뢰성. ① `TabsState(restore:)`가 `PreferencesService.openTabPaths`/`activeTabIndex`에서 탭을 복원; 탭 추가/삭제/전환·각 탭의 `$currentURL`을 관찰해 저장한다. **함정**: `@Published`는 `willSet`에서 방출하므로 sink 안에서 `currentURL`을 읽으면 *이전* 값이라 탭이 한 단계 전 폴더로 열렸다 — `DispatchQueue.main.async`로 한 틱 미뤄 새 값이 반영된 뒤 저장. `--fresh` 인자(`launchNewMFinderInstance`가 부여, `MFinderLaunch.isFreshInstance`가 판정)를 가진 새 창은 복원하지 않고 홈에서 시작. ② `ArchiveService`(시스템 zip/tar/unzip)로 이미 있던 압축 기능이 "Bandizip" 하위 메뉴에 묻혀 있어 반디집 기능처럼 보였다 — FileTableView/FileListView에서 "압축하기"(기본 zip + 형식 선택)/"압축 풀기"(단일 압축 파일)로 승격, 실제 반디집 연동은 보내기 → Bandizip에만 남김. ③ 마우스 사이드 버튼 모니터를 `.otherMouseUp` 단독 → `[.otherMouseDown, .otherMouseUp]`로 바꿔 누르는 순간(down)에 네비게이트하고 up도 소비 — 파일 테이블/사이드바가 down을 처리할 때 up이 로컬 모니터에 안 잡히던 문제 해결.
- v1.1 — Initial release.
- v1.2 — In-app GitHub Releases auto-update + Help → "업데이트 확인…".
- v1.3 — Multi-instance (File → 새 창 / Dock right-click → 새 창 열기).
- v1.4 — Favorites action renamed to "즐겨찾기에 추가/제거"; available from file list folder context menu too.
- v1.5 — Cross-instance copy/paste via system pasteboard + post-paste focus follow-through + sticky selection across reload generations.
- v1.6 — Live volume list (didMount/didUnmount) + 꺼내기 menu.
- v1.7 — RAR/7z fallback to Bandizip.app when no CLI installed + "보내기 → Bandizip" entry.
- v1.8 — Multi-select in the sidebar tree (Cmd-/Shift-click), multi-aware context menu + bulk trash dialog.
- v1.9 — Sidebar tree follows the active tab on switch (.id(ObjectIdentifier(tab))).
- v1.10 — Sidebar tree right-click → 속성 dialog (만든/수정 날짜 + async folder size via background enumerator).
- v1.11 — Cross-instance unified clipboard stack (system pasteboard is source of truth, encoded with custom `com.secondlook.MFinder.clipboard-stack` type carrying cut/copy flags and ordering) + 새로 만들기 submenu added to file-table per-file menu, file-list per-item menu, and sidebar folder right-click menu.
- v1.12 — "서버에 연결…" via `NetFSMountURLAsync` (Cmd+K + 이동 메뉴 + 네트워크 섹션 우클릭). Custom `ServerConnectDialog` (NSPanel) with URL field, recent-server list, status line. `NetworkConnectService` persists recent servers + resolves mount points via `URLResourceKey.volumeURLForRemountingKey`. `SidebarItem` gained `.server(URL)` and `.connectAction` cases; 네트워크 section now lists recents + currently-mounted remote volumes + a "서버에 연결…" action row. Right-click on a server row → 연결 / 연결 끊기 / 주소 복사 / 목록에서 제거. Package.swift links `NetFS.framework`.
- v1.25 — 브랜치 키에 섹션 추가. v1.24 keyed a branch by root URL alone, which collapses the moment a 클라우드 root is pinned to 즐겨찾기: both rows sit at `~/Library/CloudStorage/OneDrive-개인` and a root's own root is itself, so the two branches — and every folder under them — shared one identity again. `~/Desktop` only escaped because its two rows have *different* roots (`~/Desktop` vs `~`). `TreeBranch(kind:root:)` now carries `SidebarBranchKind` (favorites/thisPC/cloud); `tree.activeRoot` → `activeBranch`; `sidebarRoot(for:)` → `sidebarBranch(for:)`, which scans 즐겨찾기 first so a pinned root wins the equal-length tie against its 클라우드 twin. Identity semantics verified in a scratchpad harness (`sed -n '1,42p'` the type declarations out of FolderTreeStore.swift into a standalone main — the types have no AppKit dependency).
- v1.24 — 사이드바 트리 브랜치 독립. `SidebarItem.folder` gained a `root:` payload, so the same directory shown under two sections is two distinct items. It was one: AppKit compares sidebar items by value, so expanding 내 PC → 홈 → Desktop also expanded 즐겨찾기 → 바탕 화면, and `row(forItem:)` — first match in display order — kept scrolling the tree up to the 즐겨찾기 copy. `FolderTreeStore` expansion is now keyed by `TreeNode(root:url:)`; `expandedURLs` survives as a derived set because the FSEvents watch set is branch-agnostic (one directory watched once). `tree.activeRoot`, set by the sidebar on selection change, is the branch `ensureVisible` and `locateItem` prefer — so navigating deeper from the file list grows the branch the user last clicked in. `sidebarRootPaths()` → `sidebarRoot(for:)` (longest containing root). Expansion sync uses the exact-match `locateNode(_:)`; URL-only `locateItem(for:)` remains for selection/rename, where the caller has no branch.
- v1.23 — 사이드바 섹션 고정: 즐겨찾기/클라우드 행을 클릭해도 내 PC 브랜치로 튀지 않는다. ① `FolderTreeStore.ensureVisible` returned early only *after* stepping to the parent, so a target that is itself a sidebar root (즐겨찾기 → 바탕 화면 = `~/Desktop`) expanded `~` — the whole 내 PC → 홈 branch — and stopped there. Now the root check runs on the target first: nothing to reveal, nothing expanded. ② The converse: `locateItem`'s most-specific-root ranking (v1.22) also overruled explicit clicks, so selecting 내 PC → 홈 → Desktop jumped the highlight to 즐겨찾기. `syncSelection` now honors an already-selected row matching currentURL before consulting the ranking — ranking is for programmatic reveals only.
- v1.22 — 클라우드 사이드바 섹션 + 온라인 전용 배지 + NFC 이름 정규화. ① `FileSystemService.cloudLocations()` enumerates `~/Library/CloudStorage/<Provider>-<Account>` plus iCloud Drive; new `SidebarSection.cloud` / `SidebarItem.cloudRoot`. No cloud API — the provider's own client publishes a File Provider folder and MFinder just browses it. Reading that directory is TCC-gated, so failure returns an empty list (the permission alert belongs to `NavigationState.reload`, not to sidebar build). ② `FolderTreeStore.ensureVisible(_:stoppingAt:)` now stops at a sidebar root instead of climbing to `/`, and `locateItem(for:)` ranks matches by root-path specificity — previously a cloud subfolder materialized the 내 PC → 홈 → Library → CloudStorage chain and, since 내 PC sits higher, selection jumped out of 클라우드. ③ Online-only files: `.isUbiquitousItemKey` + `.ubiquitousItemDownloadingStatusKey` work for third-party File Providers, not just iCloud, so detection folds into the existing `resourceValues` call with no extra stat(2); the badge is composited into `FileItem.icon` (cached per base icon) so every view mode gets it free. ④ 이름 NFC로 정규화 — see the Unicode note below.
- v1.21 — Details-view column order + widths persist (PreferencesService.detailColumnOrder/detailColumnWidths; restoreColumnLayout runs in makeNSView *before* the delegate is attached so the restore's moveColumn calls don't re-save; Coordinator saves on tableViewColumnDidMove/DidResize, hidden columns included so a re-enabled column returns to its slot). Sidebar width moved out of HSplitView's implicit state into AppUIState.sidebarWidth (+ PreferencesService) with a custom SidebarResizeDivider in ContentView — the sidebar's `.id(ObjectIdentifier(tab))` made AppKit re-lay-out a fresh subview at idealWidth on every rebuild (tab switch, and a theme flip on app re-activation), silently dropping the dragged width.
- v1.20 — Built-in favorites (바탕 화면 등 6종) are now removable: PinnedFoldersService gained hiddenBuiltinPaths (persisted) + unified isInFavorites/addToFavorites/removeFromFavorites used by the sidebar buildItemMenu and the file-table folder menu; quickAccessLocations() filters hidden built-ins; 즐겨찾기 section header right-click → "숨긴 기본 항목 복원". build.sh prefers the "MFinder Dev" self-signed identity when present (stable TCC grants across updates) with ad-hoc fallback.
- v1.19 — ⌘I 정보 가져오기: 파일 메뉴 command posts `.mfinderGetInfo`; FileListView handler (guard `AppFocus.area != .sidebar`) shows item 속성 for the first selected item in list order, or 폴더 속성 when nothing is selected; the sidebar Coordinator subscribes in installObservers (guard `.sidebar`) and reuses its async-folder-size 속성 dialog.
- v1.18 — HOTFIX: v1.17's stream-copy engine passed `&buffer[written]` (inout-to-pointer on a single array element — a temporary, undefined behavior) to `OutputStream.write`, so copying any non-empty file failed with EFAULT/"incorrect format"; empty files, folder shells, and same-volume moves were unaffected, which is why the smoke test missed it. Fixed with `withUnsafeBufferPointer` + base-address offset. Engine now has a scratchpad repro harness pattern: sed `private //g` the service into a test main and exercise execute() directly.
- v1.17 — Big batch: ① async copy/move via FileOperationService (progress panel + cancel; ClipboardService.paste became completion-based `paste(into:completion:)` — all 6 call sites updated; both drop handlers build FileOperation lists). ② Undo/redo via UndoService (CommandGroup(replacing: .undoRedo) forwards to the field editor's NSUndoManager while text-editing). ③ 그룹화 기준 in the details view — FileTableView.Coordinator now has a `rows: [TableRow]` display model (group headers + items); ALL NSTableView row indices go through item(at:)/rowIndex(of:); grouping suspends during search. ④ Preview pane (⇧⌘P, QLPreviewView, Package.swift links Quartz; AppUIState.showPreviewPane). ⑤ 일괄 이름 바꾸기 (BatchRenameDialog: sequential-number or find/replace; single ⌘Z). ⑥ Header right-click column toggles (만든 날짜/확장명 added; persisted as PreferencesService.detailColumns; "위치" stays search-managed). ⑦ 자동 설치 in-app updater (UpdateInstaller). ⑧ ThemeService.followSystemAppearance — follows AppleInterfaceThemeChangedNotification; default ON unless a theme was ever hand-picked; manual pick switches it off. ⑨ Sidebar volume rows get inline ⏏ EjectVolumeButton (isEjectableVolume). ⑩ Sidebar AirDrop row (SidebarItem.airdrop: click = send selection or NSOpenPanel; drop = send). Plus: SwiftUI view modes fill their pane (ScrollView cross-axis hugging fix), type-ahead in details view.
- v1.16 — Fully-Korean menu bar (Info.plist `CFBundleDevelopmentRegion`/`CFBundleLocalizations` = ko + empty `ko.lproj` marker created by build.sh, so AppKit framework strings localize; font-size commands moved from a custom CommandMenu("보기") into the system View menu via `CommandGroup(after: .toolbar)`); ⌘W now closes the tab not the window (`CommandGroup(replacing: .saveItem)` — the File menu's system Close was winning the key-equivalent scan; ⇧⌘W = 창 닫기); 이동 메뉴 뒤로/앞으로/위로 wired up (the notifications had NO listeners — ContentView now receives them); mouse side buttons 4/5 (MX Master) → history back/forward via `.otherMouseUp` local monitor. Sidebar fixes: ⌘C/⌘X worked only until the file table's `tableViewSelectionDidChange` flipped `AppFocus` on *programmatic* selection resets (now gated on the table actually being firstResponder) + `SidebarNSOutlineView` gained responder-chain `copy:/cut:/paste:` + `validateMenuItem` so the Edit menu works for the tree; click-and-pause rename armed on a *fresh* click because the was-selected check ran after `super.mouseDown` (selection state now captured before); Esc during sidebar inline rename silently aborted the field editor — `controlTextDidEndEditing` never ran, leaving the bezel styling + `nav.renamingURL` stuck, which also blocked theme changes via the rename-active guard in `applyState()` (Coordinator now implements `control(_:textView:doCommandBy:)` for `cancelOperation` like FileTableView).
- v1.15 — Drag-and-drop now uses the same 덮어쓰기/건너뛰기/취소 conflict prompt as paste. Shared helper `askFileConflict` in Services/FileConflictPrompt.swift (nonisolated — callable from ClipboardService and the @MainActor drop delegates); both drop handlers (FileTableView acceptDrop, sidebar Coordinator acceptDrop) pre-count conflicts so the dialog can offer "남은 충돌 항목 모두 적용". 취소 aborts the remaining drops (no stack to preserve, unlike paste).
- v1.14 — Themes + font size via 설정 (⌘,): ThemeService/Theme with 라이트/다크 builtins, custom theme editor (name + 7 color wells + isDark base) persisted to UserDefaults; hardcoded chrome colors swept to theme refs; NSApp.appearance follows isDark. Font size 10–18pt (보기 메뉴 ⌘=/⌘-/⌘0) drives file table/list/sidebar fonts + row heights; the details table draws its own zebra stripes now (usesAlternatingRowBackgroundColors off — system alternates aren't themable). 탭 + 버튼 moved inside the tab scroll content (hugs last tab). Paste conflicts now prompt 덮어쓰기/건너뛰기/취소 with an apply-to-remaining checkbox (취소 keeps unpasted entries in the stack) — replaces v1.13's silent paste overwrite; DnD overwrite unchanged. Inline rename ends on focus loss (EditFocusWatcher: app deactivate / window loses key) in all three editors.
- v1.13 — Drag-and-drop overwrite semantics unified across file table, sidebar tree, and clipboard paste: a same-named item at the destination is removed first (overwrite); dropping/pasting back into an item's own folder duplicates on copy and is a no-op on move/cut (never overwrites self). Drag start cancels the click-and-pause rename timer (`cancelPendingRename`) in both the file table and sidebar so it can't open a stray edit field mid-drag. Explorer-style spring-loaded auto-expand in the sidebar (`SidebarNSOutlineView.draggingUpdated`): we override AppKit's instant spring-load and only expand a hovered collapsed folder after a 1.2s dwell timer, re-collapsing anything AppKit popped early; `springAuthorized` set tracks folders allowed to stay open for the drag.
