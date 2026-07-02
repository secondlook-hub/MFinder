import AppKit

/// One user decision about a same-named item at a copy/move destination.
enum FileConflictChoice { case overwrite, skip, cancel }

/// Modal 덮어쓰기 확인 shared by clipboard paste (⌘V) and drag-and-drop.
/// `remainingConflicts` is the number of conflicts still coming after this
/// one — when > 0 a suppression checkbox turns this answer into a blanket
/// decision (`blanket`) that the caller applies to all of them.
func askFileConflict(name: String, remainingConflicts: Int,
                     blanket: inout FileConflictChoice?) -> FileConflictChoice {
    let alert = NSAlert()
    alert.messageText = "\"\(name)\"이(가) 이미 있습니다"
    alert.informativeText = "대상 폴더에 같은 이름의 항목이 있습니다. 덮어쓰면 기존 항목이 삭제되며 되돌릴 수 없습니다."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "덮어쓰기")
    alert.addButton(withTitle: "건너뛰기")
    alert.addButton(withTitle: "취소")
    if remainingConflicts > 0 {
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "남은 충돌 항목 \(remainingConflicts)개에도 모두 적용"
    }
    let response = alert.runModal()
    let choice: FileConflictChoice
    switch response {
    case .alertFirstButtonReturn:  choice = .overwrite
    case .alertSecondButtonReturn: choice = .skip
    default:                       choice = .cancel
    }
    if remainingConflicts > 0, alert.suppressionButton?.state == .on, choice != .cancel {
        blanket = choice
    }
    return choice
}
