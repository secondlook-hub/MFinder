import SwiftUI
import AppKit

/// Editable NSTextField overlay used by SwiftUI view modes (icons / tile / list /
/// content) when `nav.renamingURL == item.url`. The details view has its own
/// editable NSTextField inside its NSTableCellView and doesn't need this.
struct RenameTextField: NSViewRepresentable {
    let initialName: String
    let isDirectory: Bool
    let fontSize: CGFloat
    let alignment: NSTextAlignment
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    /// Backwards-compatible convenience init used by the SwiftUI file views
    /// that already have a `FileItem` handy. Tree code passes `initialName` /
    /// `isDirectory` directly.
    init(item: FileItem,
         fontSize: CGFloat,
         alignment: NSTextAlignment,
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialName = item.name
        self.isDirectory = item.isDirectory
        self.fontSize = fontSize
        self.alignment = alignment
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    init(initialName: String,
         isDirectory: Bool,
         fontSize: CGFloat,
         alignment: NSTextAlignment,
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialName = initialName
        self.isDirectory = isDirectory
        self.fontSize = fontSize
        self.alignment = alignment
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusSeizingTextField {
        let tf = FocusSeizingTextField()
        tf.stringValue = initialName
        tf.font = NSFont.systemFont(ofSize: fontSize)
        tf.alignment = alignment
        tf.isEditable = true
        tf.isSelectable = true
        tf.isBezeled = true
        tf.bezelStyle = .squareBezel
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        tf.focusRingType = .default
        tf.lineBreakMode = .byTruncatingTail
        tf.usesSingleLineMode = true
        tf.delegate = context.coordinator
        // For files with an extension, select just the basename (so typing
        // replaces the name but keeps the extension). For directories — and
        // for files without an extension — place the caret at the end with
        // no selection, so the original name stays clearly visible and the
        // user can edit it directly instead of wiping it out with the first
        // keystroke.
        if !isDirectory, let dotRange = initialName.range(of: ".", options: .backwards) {
            let baseLen = initialName.distance(from: initialName.startIndex, to: dotRange.lowerBound)
            tf.desiredInitialSelection = NSRange(location: 0, length: baseLen)
        } else {
            tf.desiredInitialSelection = NSRange(location: initialName.count, length: 0)
        }
        // Wire the field back to the coordinator so the delegate can clear
        // the grace lock on intentional commit/cancel paths.
        context.coordinator.boundField = tf
        return tf
    }

    func updateNSView(_ nsView: FocusSeizingTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.boundField = nsView
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameTextField
        weak var boundField: FocusSeizingTextField?
        private var settled = false
        private var didEditText = false

        init(_ parent: RenameTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            didEditText = true
            // Once the user has actually typed, we can let the field resign
            // first responder normally (e.g. clicking elsewhere should commit).
            boundField?.releaseResignLock()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !settled, let tf = obj.object as? NSTextField else { return }
            // If the field's window is gone, the NSView is being torn down by
            // SwiftUI rather than the user dismissing the edit. Skip the
            // commit/cancel callbacks so a transient teardown doesn't clear
            // nav.renamingURL and cause a visible flicker.
            if tf.window == nil { return }
            settled = true
            // If end-editing fires before the user typed a single character,
            // this is almost always a stray focus loss (AppKit restoring a
            // previous first responder after a context menu dismiss, or some
            // other pane stealing the editor). Treat as cancel so the row
            // exits rename mode cleanly without a no-op commit.
            if didEditText {
                parent.onCommit(tf.stringValue)
            } else {
                parent.onCancel()
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                guard !settled else { return true }
                settled = true
                boundField?.releaseResignLock()
                parent.onCancel()
                return true
            }
            // Treat Return / Enter as commit even when no text changed (Finder
            // parity — pressing Return on an unchanged name dismisses the
            // editor with the original name).
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                guard !settled, let tf = control as? NSTextField else { return false }
                settled = true
                boundField?.releaseResignLock()
                parent.onCommit(tf.stringValue)
                return true
            }
            return false
        }
    }
}

/// NSTextField subclass that reliably seizes first responder once it's been
/// added to a window, and refuses to give it up if no user event is driving
/// the resign (which catches AppKit's deferred focus restoration after a
/// context menu dismiss). Any real user input — mouse click anywhere, key
/// press — drives `NSApp.currentEvent` and is therefore allowed through, so
/// the user can always escape the editor by clicking elsewhere or pressing
/// Return / Escape.
final class FocusSeizingTextField: NSTextField {
    var desiredInitialSelection: NSRange?
    private var seized = false
    /// True between focus claim and a short grace window; used as a fallback
    /// guard so that even an "I don't know what fired this" resign attempt
    /// during the brief setup phase doesn't take the editor down before the
    /// user has a chance to use it.
    private var setupWindowOpen = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !seized, window != nil else { return }
        seized = true
        setupWindowOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.setupWindowOpen = false
        }
        attemptFocus(remaining: 6, delay: 0)
    }

    func releaseResignLock() {
        setupWindowOpen = false
    }

    override func resignFirstResponder() -> Bool {
        // The presence of an NSApp.currentEvent of an input kind means a real
        // user action is causing the resign — allow it. AppKit's automatic
        // focus restoration (after a menu dismiss, for example) has no
        // associated current event and is what we want to refuse during the
        // brief setup window.
        if let event = NSApp.currentEvent {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown,
                 .leftMouseUp, .rightMouseUp, .otherMouseUp,
                 .keyDown, .keyUp:
                return super.resignFirstResponder()
            default:
                break
            }
        }
        if setupWindowOpen { return false }
        return super.resignFirstResponder()
    }

    private func attemptFocus(remaining: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, let window = self.window else { return }
            guard self.superview != nil else { return }
            if window.firstResponder === self || self.currentEditor() != nil {
                self.applyInitialSelection()
                return
            }
            let ok = window.makeFirstResponder(self)
            if ok {
                self.applyInitialSelection()
            } else if remaining > 1 {
                self.attemptFocus(remaining: remaining - 1, delay: 0.03)
            }
        }
    }

    private func applyInitialSelection() {
        guard let range = desiredInitialSelection,
              let editor = self.currentEditor() as? NSTextView else { return }
        editor.selectedRange = range
        desiredInitialSelection = nil
    }
}
