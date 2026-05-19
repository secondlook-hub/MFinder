# MFinder — Working Notes

A skim-first orientation for future sessions. Code is the source of truth — this file captures the things that aren't obvious from reading source: conventions, gotchas, and the release flow.

## Project shape

- Native macOS Windows-Explorer-style file manager. SwiftUI shell with AppKit views in the spots where SwiftUI's NSTextField/focus model is unreliable (sidebar tree, details file table).
- Korean UI throughout. Sidebar sections: **즐겨찾기 / 내 PC / 네트워크**.
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
│   ├── UpdateChecker.swift       GitHub Releases poll, semver compare.
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
    │                                 gesture races.
    └── AddressBar / CommandBar / TabBar / StatusBar / ClipboardStackView
```

## Patterns to follow

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

- **`.onTapGesture` consumes events** before child NSViews see them. That's why the sidebar tree had to move from SwiftUI rows to NSOutlineView — the inline NSTextField rename kept losing focus to the row's gesture recognizer. If you ever wrap an editable NSView in a SwiftUI view with gestures, the gestures will fight focus.
- **Reload race after paste**: `NavigationState.reload` uses `loadGeneration` to cancel obsolete reloads, but the `thenSelect:` target lives outside the closure (`pendingSelection`) so a cancelled reload doesn't lose the selection — the next successful reload reapplies it.
- **Window must accept mouse-moved events** for the sidebar's click-and-pause rename cancel-on-leave: `ov.window?.acceptsMouseMovedEvents = true` is set in `handleMouseDown`.
- **`controlTextDidEndEditing` fires on view teardown**, not just user dismissal. `RenameTextField.Coordinator` guards with `if tf.window == nil { return }` so a SwiftUI re-render-tear-down doesn't accidentally commit/cancel.
- **`NSPasteboard` doesn't have a change notification** — `ClipboardService` snapshots `changeCount` on `NSApplication.didBecomeActive` to refresh published state.

## Version history (one line)

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
