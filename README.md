# MFinder

A native macOS file manager with a Windows-Explorer-style layout, built with SwiftUI + AppKit.

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Tabs** — Multi-tab browsing with drag-free reordering shortcuts (Cmd+T / Cmd+W, Cmd+Shift+]/[ to switch)
- **View Modes** — Details (native NSTableView), List, Small / Medium / Large / Extra-Large Icons, Tiles, Content
- **NSOutlineView Sidebar** — 즐겨찾기 (favorites with pinning), 내 PC (volumes), 네트워크 sections under a single outline view; inline folder rename via AppKit's `editColumn` field editor
- **Multi-Select in Tree** — Cmd-click / Shift-click multiple folders in the sidebar to copy, cut, trash, pin, alias, or reveal them all at once. Single-target actions (rename, paste-into, eject) stay scoped to the right-clicked row
- **Live Volume List** — Mounted DMGs, external drives, and network shares appear in the 내 PC section the moment they mount; right-click → 꺼내기 to unmount
- **Inline Rename** — Right-click → "이름 바꾸기", F2, or click-and-pause on an already-selected row. Mouse must stay on the row for the pause-to-rename to activate; cancels if the cursor leaves
- **Address Bar** — Breadcrumb path navigation, editable URL field, jump to any ancestor
- **Spotlight Search** — Backed by NSMetadataQuery with token parsing: `-exclude` words, `"quoted phrases"`, content + filename matching. Inline snippet preview in the file list
- **Live File-System Watcher** — `kqueue`-based vnode watcher reliably refreshes the file list and tree branches as the contents change on disk (including from Finder or shell)
- **Clipboard Stack** — Cut, copy, and paste multiple selections; a single ⌘V drains the entire stack into the current folder. Cut items are dimmed in both the file list and the sidebar tree. The stack is shared across every running MFinder instance via the system pasteboard, so a multi-file copy in one window is fully paste-able in any other
- **Drag & Drop** — Drop file URLs from anywhere (Finder, other apps, this app's panes); hold Option to copy, default is move. Drop onto a tree folder to send items there
- **Quick Look** — Spacebar previews the selection in the system Quick Look panel
- **Archive (Bandizip)** — Right-click → Bandizip submenu to compress to .zip/.7z/.tar.gz/etc., or extract to here / to a subfolder / to a chosen location. RAR / 7z fall back to Bandizip.app when no CLI extractor (`unrar`, `unar`, `7z`) is installed
- **Send to Bandizip** — "보내기 → Bandizip" hands selected files off to Bandizip.app when it's installed
- **Send To** — 바탕 화면 (바로 가기), 다운로드, 문서, AirDrop, 메일, 메시지
- **Trash / Delete** — ⌫ or ⌘⌫ moves to Trash via Finder (recoverable), ⌥⌘⌫ deletes immediately with confirmation, ⌘⇧⌫ empties the entire Trash
- **Tab Bar** — Drag tabs to reorder; close-other-tabs from the context menu; tabs share the sidebar tree state
- **Pinned Favorites** — Add any folder to the 즐겨찾기 sidebar section via the right-click menu in either the sidebar tree or the file list ("즐겨찾기에 추가" / "즐겨찾기에서 제거")
- **Permission Guidance** — TCC-protected folders (OneDrive / Google Drive / Dropbox under `~/Library/CloudStorage`) trigger a clear dialog with a one-click jump to System Settings → Privacy & Security → Full Disk Access
- **Symlink Creation** — "바로 가기 만들기" creates a Finder-style alias (POSIX symlink) next to the source folder
- **File Properties** — 속성 dialog on file-list items (size, type, dates, permissions) and on sidebar tree folders (만든/수정 날짜 + async-computed total size)
- **Auto Update** — Checks GitHub Releases on launch (and on-demand via Help → "업데이트 확인…") and offers a one-click download when a newer version is available
- **Multiple Instances** — Run several independent MFinder processes side by side, each with its own tabs and sidebar tree. The clipboard stack is unified across all running instances. Launch via File → 새 창 (Cmd+N) or Dock icon right-click → 새 창 열기. Copy in one instance, paste in another — the destination instance auto-focuses and scrolls to the newly pasted item.
- **Connect to Server** — 이동 → "서버에 연결…" (⌘K) or right-click on the 네트워크 sidebar section opens a Finder-style dialog for `smb://`, `afp://`, `ftp://`, `nfs://`, and WebDAV URLs. Mounts via `NetFS.framework` so the system's credentials sheet and Keychain are reused. Recent servers are persisted and listed under the 네트워크 section — right-click → 연결 / 연결 끊기 / 목록에서 제거
- **Korean UI** — Native Korean menu labels throughout

## Install

Download `MFinder.dmg` from [Releases](https://github.com/secondlook-hub/MFinder/releases) and drag MFinder to your Applications folder.

## Build from Source

```bash
git clone https://github.com/secondlook-hub/MFinder.git
cd MFinder
./build.sh release        # produces MFinder.app
scripts/makeDmg.sh         # produces MFinder.dmg (with /Applications shortcut)
```

Requires **Swift 5.9** and **macOS 13.0 Ventura** or later.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+N | New Window (independent instance) |
| Cmd+T | New Tab |
| Cmd+W | Close Tab |
| Cmd+Shift+] | Next Tab |
| Cmd+Shift+[ | Previous Tab |
| Cmd+[ | Back |
| Cmd+] | Forward |
| Cmd+Up | Up one folder |
| Space | Quick Look the selection |
| F2 | Rename selected |
| Cmd+C | Copy selection |
| Cmd+X | Cut selection |
| Cmd+V | Paste from clipboard stack |
| Cmd+K | Connect to Server |
| ⌫ / Cmd+⌫ | Move selection to Trash |
| Option+Cmd+⌫ | Delete immediately (with confirmation) |
| Shift+Cmd+⌫ | Empty Trash |
| Drop + Option | Copy on drop (default is move) |
| Right-click | Context menu |

## Project Structure

```
MFinder/
├── Package.swift
├── build.sh                                 # Release builder → MFinder.app
├── scripts/
│   ├── makeDmg.sh                           # DMG packager with /Applications symlink
│   └── makeIcon.swift                       # AppIcon.icns generator
├── Resources/
│   ├── Info.plist
│   ├── AppIcon.icns
│   └── AppIcon.iconset/
└── Sources/MFinder/
    ├── MFinderApp.swift                     # App entry, menu commands, key monitor (F2/Space/Delete)
    ├── ContentView.swift                    # Top-level layout (tabs + panes)
    ├── Models/
    │   ├── NavigationState.swift            # Per-tab nav, sort, search, FS watcher
    │   ├── TabsState.swift                  # Tab collection
    │   ├── FolderTreeStore.swift            # Tree expansion + children cache
    │   └── FileItem.swift
    ├── Services/
    │   ├── FileSystemService.swift          # Listing, quick-access locations, this PC, reveal-in-Finder
    │   ├── FileSystemWatcher.swift          # kqueue-backed vnode watcher
    │   ├── ClipboardService.swift           # Multi-item cut/copy/paste stack
    │   ├── PinnedFoldersService.swift       # Persistent favorites
    │   ├── ArchiveService.swift             # Bandizip integration
    │   ├── SearchSnippetService.swift       # Inline match preview
    │   ├── QuickLookCoordinator.swift
    │   ├── UpdateChecker.swift              # GitHub Releases update checker
    │   └── PreferencesService.swift
    └── Views/
        ├── AddressBar.swift
        ├── CommandBar.swift                 # Cut/Copy/Paste/Rename/Share/Delete + new menu
        ├── TabBar.swift
        ├── SidebarView.swift                # SwiftUI host for the outline sidebar
        ├── SidebarOutlineView.swift         # NSOutlineView wrapper for the entire sidebar tree
        ├── FileListView.swift               # Icons / List / Tiles / Content view modes
        ├── FileTableView.swift              # Details view (NSTableView with editColumn rename)
        ├── RenameTextField.swift            # Shared inline rename NSTextField for non-details views
        ├── ClipboardStackView.swift         # Stack indicator dropdown
        ├── StatusBar.swift
        └── CommandBar.swift
```

## License

MIT
