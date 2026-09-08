import DukouCore
import SwiftUI

struct QuickForwardFooter: View {
    let isBusy: Bool
    let canRun: Bool
    let savesToFolder: Bool
    let status: String?
    let elapsedSeconds: Double?
    let identifierPrefix: String
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(L10n.text("执行时请勿操作电脑，按 ESC 中断。"))
                    .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifierPrefix + ".guidance")
                if let status {
                    HStack(alignment: .top, spacing: Space.s) {
                        if isBusy { ProgressView().controlSize(.small) }
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(status).font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier(identifierPrefix + ".status")
                            if let elapsedSeconds, !isBusy {
                                Text(L10n.format("%.1f 秒", elapsedSeconds))
                                    .font(Typo.paneCaption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
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
}
