import SwiftUI
import AppKit

@main
struct MFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var updateChecker = UpdateChecker()

    var body: some Scene {
        WindowGroup("MFinder") {
            ContentView()
                .environmentObject(updateChecker)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 창") {
                    launchNewMFinderInstance()
                }.keyboardShortcut("n", modifiers: .command)
                Button("새 탭") {
                    NotificationCenter.default.post(name: .mfinderNewTab, object: nil)
                }.keyboardShortcut("t", modifiers: .command)
            }
            // Replace the system Close (⌘W): the menu bar resolves key
            // equivalents left-to-right, so the File menu's Close used to
            // swallow ⌘W before the 탭 menu's 탭 닫기 ever saw it — closing
            // the window (and quitting, via terminate-after-last-window)
            // instead of the tab.
            CommandGroup(replacing: .saveItem) {
                Button("탭 닫기") {
                    NotificationCenter.default.post(name: .mfinderCloseTab, object: nil)
                }.keyboardShortcut("w", modifiers: .command)
                Button("창 닫기") {
                    NSApp.keyWindow?.performClose(nil)
                }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu("탭") {
                Button("새 탭") {
                    NotificationCenter.default.post(name: .mfinderNewTab, object: nil)
                }.keyboardShortcut("t", modifiers: .command)
                Button("탭 닫기") {
                    NotificationCenter.default.post(name: .mfinderCloseTab, object: nil)
                }.keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("다음 탭") {
                    NotificationCenter.default.post(name: .mfinderNextTab, object: nil)
                }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("이전 탭") {
                    NotificationCenter.default.post(name: .mfinderPrevTab, object: nil)
                }.keyboardShortcut("[", modifiers: [.command, .shift])
            }
            // Insert into the system View menu (AppKit already owns one for
            // "전체 화면 시작") instead of a separate CommandMenu, so there is
            // a single 보기 menu rather than a custom Korean one next to the
            // English system one.
            CommandGroup(after: .toolbar) {
                Divider()
                Button("글자 크게") {
                    ThemeService.shared.increaseFontSize()
                }.keyboardShortcut("=", modifiers: .command)
                Button("글자 작게") {
                    ThemeService.shared.decreaseFontSize()
                }.keyboardShortcut("-", modifiers: .command)
                Button("글자 기본 크기") {
                    ThemeService.shared.resetFontSize()
                }.keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("이동") {
                Button("뒤로") {
                    NotificationCenter.default.post(name: .mfinderGoBack, object: nil)
                }.keyboardShortcut("[", modifiers: .command)
                Button("앞으로") {
                    NotificationCenter.default.post(name: .mfinderGoForward, object: nil)
                }.keyboardShortcut("]", modifiers: .command)
                Button("위로") {
                    NotificationCenter.default.post(name: .mfinderGoUp, object: nil)
                }.keyboardShortcut(.upArrow, modifiers: [.command])
                Divider()
                Button("서버에 연결…") {
                    NotificationCenter.default.post(name: .mfinderConnectToServer, object: nil)
                }.keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("업데이트 확인…") {
                    Task { await updateChecker.checkForUpdates(manual: true) }
                }
            }
        }

        // App menu → 설정… (⌘,): font size + theme management.
        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let mfinderGoBack         = Notification.Name("mfinder.goBack")
    static let mfinderGoForward      = Notification.Name("mfinder.goForward")
    static let mfinderGoUp           = Notification.Name("mfinder.goUp")
    static let mfinderQuickLook      = Notification.Name("mfinder.quickLook")
    static let mfinderNewTab         = Notification.Name("mfinder.newTab")
    static let mfinderCloseTab       = Notification.Name("mfinder.closeTab")
    static let mfinderNextTab        = Notification.Name("mfinder.nextTab")
    static let mfinderPrevTab        = Notification.Name("mfinder.prevTab")
    static let mfinderRenameSelected = Notification.Name("mfinder.renameSelected")
    static let mfinderTrashSelected     = Notification.Name("mfinder.trashSelected")
    static let mfinderEmptyTrash        = Notification.Name("mfinder.emptyTrash")
    static let mfinderDeleteImmediately = Notification.Name("mfinder.deleteImmediately")
    static let mfinderTreeCopy          = Notification.Name("mfinder.treeCopy")
    static let mfinderTreeCut           = Notification.Name("mfinder.treeCut")
    static let mfinderTreePaste         = Notification.Name("mfinder.treePaste")
    static let mfinderConnectToServer   = Notification.Name("mfinder.connectToServer")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
        installMouseMonitor()
    }

    /// Mouse side buttons (e.g. Logitech MX Master back/forward) navigate
    /// history, browser-style. AppKit reports them as "other" mouse buttons:
    /// buttonNumber 3 = back, 4 = forward.
    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
            switch event.buttonNumber {
            case 3:
                NotificationCenter.default.post(name: .mfinderGoBack, object: nil)
                return nil
            case 4:
                NotificationCenter.default.post(name: .mfinderGoForward, object: nil)
                return nil
            default:
                return event
            }
        }
    }

    /// Adds custom items to the Dock icon's right-click menu. Custom items
    /// appear above the system-provided "Options", "Show All Windows",
    /// "Hide", and "Quit" entries.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "새 창 열기", action: #selector(openNewInstanceFromDock(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openNewInstanceFromDock(_ sender: Any?) {
        // Dock menu actions arrive on the main thread but as a nonisolated
        // selector entry point; bounce into MainActor to call the
        // @MainActor helper.
        MainActor.assumeIsolated {
            launchNewMFinderInstance()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = keyMonitor   { NSEvent.removeMonitor(m) }
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
    }

    /// Intercepts top-level key events.
    ///   Space            → Quick Look
    ///   F2               → Rename selected
    ///   ⌫ / ⌘⌫           → Move selected to Trash
    ///   ⌘⇧⌫              → Empty Trash (Finder standard, no selection needed)
    ///   ⌥⌘⌫              → Delete Immediately (skip trash, with confirmation)
    /// All pass through when a text editor has focus (so inline edits keep typing).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Skip if a text field / field editor has focus.
            if let win = NSApp.keyWindow, win.firstResponder is NSText {
                return event
            }
            // Strip non-semantic flags (some external keyboards set .function or
            // .numericPad on their Delete keys; capsLock state is irrelevant).
            let noise: NSEvent.ModifierFlags = [.capsLock, .numericPad, .function, .help]
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(noise)
            let code = event.keyCode

            // Cmd+X / Cmd+C / Cmd+V — only intercept when the sidebar tree has
            // focus. When the file list (NSTableView) is focused, leave the
            // event alone so the responder chain delivers it to the table's
            // @objc cut/copy/paste methods, preserving existing behavior.
            if mods == [.command], AppFocus.area == .sidebar,
               let chars = event.charactersIgnoringModifiers, chars.count == 1 {
                switch chars {
                case "c":
                    NotificationCenter.default.post(name: .mfinderTreeCopy, object: nil)
                    return nil
                case "x":
                    NotificationCenter.default.post(name: .mfinderTreeCut, object: nil)
                    return nil
                case "v":
                    NotificationCenter.default.post(name: .mfinderTreePaste, object: nil)
                    return nil
                default:
                    break
                }
            }

            // Delete keys (51 = Backspace, 117 = Forward Delete from extended/external keyboards)
            if code == 51 || code == 117 {
                let isCmd   = mods.contains(.command)
                let isShift = mods.contains(.shift)
                let isOpt   = mods.contains(.option)
                let extras  = mods.subtracting([.command, .shift, .option])
                if extras.isEmpty {
                    // ⌘⇧⌫ — Finder standard: empty entire Trash (no selection needed)
                    if isCmd && isShift && !isOpt {
                        NotificationCenter.default.post(name: .mfinderEmptyTrash, object: nil)
                        return nil
                    }
                    // ⌥⌘⌫ — Finder standard: delete selected immediately (skip Trash, with confirmation)
                    if isCmd && isOpt && !isShift {
                        NotificationCenter.default.post(name: .mfinderDeleteImmediately, object: nil)
                        return nil
                    }
                    // ⌫ / ⌘⌫ — Move selected to Trash
                    if (isCmd && !isShift && !isOpt) || mods.isEmpty {
                        NotificationCenter.default.post(name: .mfinderTrashSelected, object: nil)
                        return nil
                    }
                }
            }

            // No-modifier shortcuts (Space, F2)
            guard mods.isEmpty else { return event }
            switch code {
            case 49:   // Space → Quick Look
                NotificationCenter.default.post(name: .mfinderQuickLook, object: nil)
                return nil
            case 120:  // F2 → Rename selected
                NotificationCenter.default.post(name: .mfinderRenameSelected, object: nil)
                return nil
            default:
                return event
            }
        }
    }
}

/// Launches an additional MFinder process side-by-side with the current one.
/// Uses `createsNewApplicationInstance` so LaunchServices spawns a fresh
/// process (equivalent to running `open -n MFinder.app`) instead of just
/// activating the already-running instance, giving each window its own state,
/// clipboard stack, sidebar tree, and tabs.
@MainActor
func launchNewMFinderInstance() {
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.activates = true
    NSWorkspace.shared.openApplication(
        at: Bundle.main.bundleURL,
        configuration: config,
        completionHandler: { _, error in
            if let error {
                NSLog("MFinder.newInstance: openApplication failed: \(error.localizedDescription)")
            }
        }
    )
}
