import AppKit
import QuickLookUI

@MainActor
final class QuickLookCoordinator: NSObject {
    static let shared = QuickLookCoordinator()

    private var urls: [URL] = []
    private var currentIndex: Int = 0

    /// Opens Quick Look panel for the given URLs. If panel is already visible,
    /// either updates its contents (if URLs changed) or closes it (Finder behaviour).
    func toggle(urls newURLs: [URL]) {
        let panel = QLPreviewPanel.shared()
        if !newURLs.isEmpty {
            urls = newURLs
            currentIndex = 0
        }
        if let panel, panel.isVisible {
            // If user pressed Space again with same selection → close.
            // If selection changed, just refresh.
            if newURLs.isEmpty || newURLs.map(\.path) == urls.map(\.path) {
                panel.orderOut(nil)
                return
            }
            panel.reloadData()
            return
        }
        guard !urls.isEmpty, let panel else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    var isVisible: Bool {
        QLPreviewPanel.shared()?.isVisible ?? false
    }
}

extension QuickLookCoordinator: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

extension QuickLookCoordinator: @preconcurrency QLPreviewPanelDelegate {
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Forward arrow keys to the panel itself for navigation between items.
        if event.type == .keyDown, event.keyCode == 53 {  // Escape
            panel.orderOut(nil)
            return true
        }
        return false
    }
}
