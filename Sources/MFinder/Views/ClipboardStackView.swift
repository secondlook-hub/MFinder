import SwiftUI

/// Popover content for the clipboard stack — shown when the status bar
/// "복사 대기" pill is clicked. Lists each pending entry with its mode
/// (✂ cut / 📄 copy), allows removing individual entries, and offers
/// paste-into-current-folder + clear actions.
struct ClipboardStackView: View {
    @EnvironmentObject var nav: NavigationState
    @ObservedObject var clipboard = ClipboardService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 420, height: 380)
    }

    private var header: some View {
        HStack {
            Text("복사 대기")
                .font(.system(size: 13, weight: .semibold))
            Text("\(clipboard.stack.count)개")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Button("초기화") { clipboard.clear() }
                .buttonStyle(.borderless)
                .disabled(clipboard.stack.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(clipboard.stack) { entry in
                    row(entry)
                    Divider().opacity(0.3)
                }
                if clipboard.stack.isEmpty {
                    Text("비어 있음")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
        }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isCut ? "scissors" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundColor(entry.isCut ? .orange : ThemeService.shared.theme.accent.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.url.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(entry.url.deletingLastPathComponent().path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                clipboard.remove(entry.url)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.55))
            }
            .buttonStyle(.plain)
            .help("스택에서 제거")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("닫기") { dismiss() }
                .buttonStyle(.bordered)
            Button("여기에 모두 붙여넣기") {
                pasteAll()
            }
            .buttonStyle(.borderedProminent)
            .disabled(clipboard.stack.isEmpty)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func pasteAll() {
        do {
            let created = try clipboard.paste(into: nav.currentURL)
            nav.reload(thenSelect: Set(created))
            dismiss()
        } catch {
            let alert = NSAlert()
            alert.messageText = "붙여넣기 실패"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
    }
}
