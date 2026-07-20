import AppKit
import Foundation

/// 이름 NFC로 정규화 — converts existing decomposed (NFD) filenames to NFC.
///
/// Explicit rather than automatic: renaming files the user merely browsed past
/// would surface outside MFinder (Git sees renames, cloud sync re-uploads,
/// hardcoded paths break), so this runs only when asked and shows exactly what
/// it will touch first. The whole run is one ⌘Z entry.
@MainActor
func promptNormalizeNames(_ urls: [URL], nav: NavigationState) {
    guard let first = urls.first else { return }

    if FilenameNormalization.isFutile(at: first) {
        showTreeAlert("이 볼륨에서는 정규화할 수 없습니다",
                      "HFS+ 볼륨은 파일 이름을 항상 NFD로 저장합니다. NFC로 바꿔도 파일 시스템이 즉시 되돌리기 때문에 의미가 없습니다.")
        return
    }

    let controller = NormalizePreview(urls: urls)
    if controller.shallowPlan.isEmpty && controller.deepPlan().isEmpty {
        showTreeAlert("정규화할 항목이 없습니다",
                      "선택한 항목과 그 하위 항목의 이름이 이미 모두 NFC입니다.")
        return
    }

    let alert = NSAlert()
    alert.messageText = "이름 NFC로 정규화 (\(urls.count)개 선택)"
    alert.informativeText = "화면에 보이는 글자는 그대로이고, 디스크에 저장되는 코드만 바뀝니다.\nGit 저장소나 동기화 폴더에서는 이름이 바뀐 것으로 인식될 수 있습니다."
    alert.addButton(withTitle: "정규화")
    alert.addButton(withTitle: "취소")
    alert.accessoryView = controller.accessoryView
    controller.render()

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let pairs = controller.currentPlan
    guard !pairs.isEmpty else { return }

    let (done, firstErr) = FilenameNormalization.apply(pairs)
    UndoService.shared.register(.renameBytes(pairs: done), label: "이름 정규화")

    // Only top-level renames are worth re-selecting; descendants aren't visible
    // in the current pane.
    let parentPath = nav.currentURL.path
    let visible = done
        .map { URL(fileURLWithPath: $0.to) }
        .filter { $0.deletingLastPathComponent().path == parentPath }
    nav.reload(thenSelect: Set(visible))

    if let err = firstErr {
        showTreeAlert("일부 항목의 이름을 바꾸지 못했습니다", err)
    }
}

/// Owns the accessory view and recomputes the preview when 하위 폴더 포함 is
/// toggled. A class because NSButton needs a target for its action.
@MainActor
private final class NormalizePreview: NSObject {
    let urls: [URL]
    let shallowPlan: [(from: String, to: String)]
    private var cachedDeepPlan: [(from: String, to: String)]?

    private let checkbox = NSButton(checkboxWithTitle: "하위 폴더 포함", target: nil, action: nil)
    private let textView = NSTextView()
    let accessoryView = NSStackView()

    init(urls: [URL]) {
        self.urls = urls
        self.shallowPlan = FilenameNormalization.plan(for: urls, recursive: false)
        super.init()

        checkbox.target = self
        checkbox.action = #selector(toggled)

        textView.isEditable = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true

        accessoryView.orientation = .vertical
        accessoryView.alignment = .leading
        accessoryView.spacing = 8
        accessoryView.addArrangedSubview(checkbox)
        accessoryView.addArrangedSubview(scroll)
        accessoryView.layoutSubtreeIfNeeded()
        accessoryView.frame = NSRect(origin: .zero, size: accessoryView.fittingSize)
    }

    /// Walking a deep tree isn't free, so it happens on first toggle, not on open.
    func deepPlan() -> [(from: String, to: String)] {
        if let cached = cachedDeepPlan { return cached }
        let plan = FilenameNormalization.plan(for: urls, recursive: true)
        cachedDeepPlan = plan
        return plan
    }

    var currentPlan: [(from: String, to: String)] {
        checkbox.state == .on ? deepPlan() : shallowPlan
    }

    @objc private func toggled() { render() }

    func render() {
        let plan = currentPlan
        guard !plan.isEmpty else {
            textView.string = checkbox.state == .on
                ? "정규화할 항목이 없습니다."
                : "선택한 항목 자체는 이미 NFC입니다.\n하위 폴더 포함을 켜면 안쪽 항목을 확인합니다."
            return
        }
        // Shallowest first reads better than the deepest-first apply order.
        let lines = plan
            .sorted { $0.from.count < $1.from.count }
            .map { ($0.from as NSString).lastPathComponent }
        textView.string = "\(plan.count)개 항목:\n\n" + lines.joined(separator: "\n")
    }
}
