import DukouCore
import SwiftUI

/// The one action of a quick forward page, pinned under the scrolling form.
///
/// It lived at the end of the form, where opening 附加 Prompt pushed it off the
/// bottom of the window: the page's only button, and the message saying why it
/// had not worked, were both somewhere the user had to scroll to find.
struct QuickForwardFooter: View {
    let isBusy: Bool
    let canRun: Bool
    let savesToFolder: Bool
    let status: String?
    let error: String?
    let elapsedSeconds: Double?
    let identifierPrefix: String
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.stroke).frame(height: Stroke.hairline)
            VStack(alignment: .leading, spacing: Space.s) {
                if let error { Notice(error, tone: .bad) }
                HStack(alignment: .center, spacing: Space.l) {
                    HStack(alignment: .center, spacing: Space.s) {
                        if isBusy { ProgressView().controlSize(.small) }
                        // One line at a time. The warning is for before the
                        // click; once there is something to report it has been
                        // read, and the HUD repeats it for the whole run.
                        if let status {
                            Text(status + (elapsedSeconds.map { isBusy ? "" : " · " + L10n.format("%.1f 秒", $0) } ?? ""))
                                .accessibilityIdentifier(identifierPrefix + ".status")
                        } else {
                            Text(L10n.text("执行时请勿操作电脑，按 ESC 中断。"))
                                .accessibilityIdentifier(identifierPrefix + ".guidance")
                        }
                    }
                    .font(Typo.paneCaption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isBusy {
                        Button(L10n.text("取消"), action: onCancel)
                            .buttonStyle(SettingsActionButtonStyle())
                            .fixedSize()
                            .accessibilityIdentifier(identifierPrefix + ".cancel")
                    } else {
                        Button(savesToFolder ? L10n.text("开始保存") : L10n.text("开始转发"), action: onStart)
                            .buttonStyle(SettingsActionButtonStyle(primary: true))
                            .fixedSize()
                            .disabled(!canRun)
                            .accessibilityIdentifier(identifierPrefix + ".run")
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, Space.m)
        }
        .background(Theme.raised)
    }
}
