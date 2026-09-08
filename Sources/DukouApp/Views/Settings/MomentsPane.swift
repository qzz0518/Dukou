import DukouCore
import SwiftUI

struct MomentsPane: View {
    @ObservedObject var forward: MomentsQuickForward
    @ObservedObject var authorization: AccessibilityAuthorization
    @ObservedObject var preferences: Preferences
    @State private var amount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(L10n.text("按时间整理朋友圈，打包成 ZIP。"))
                .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsSection(title: L10n.text("转发内容"), systemImage: "photo.on.rectangle.angled", spacing: Space.m) {
                HStack(spacing: Space.s) {
                    Text(L10n.text("最近")).font(Typo.paneBody)
                    TextField(L10n.text("范围数量"), text: $amount)
                        .textFieldStyle(SettingsTextFieldStyle(numeric: true, invalid: !forward.draft.isValid))
                        .multilineTextAlignment(.center)
                        .frame(width: min(176, max(64, CGFloat(amount.count) * 8 + 24)))
                        .accessibilityIdentifier("moments.amount")
                        .onChange(of: amount) { _, value in
                            let digits = WeChatForwardRange.digits(value)
                            if digits != value { amount = digits }
                            forward.draft.count = Int(digits) ?? 0
                        }
                    Text(L10n.text("条朋友圈")).font(Typo.paneBody)
                    Spacer(minLength: Space.s)
                }
                if !forward.draft.isValid {
                    Text(!amount.isEmpty && Int(amount) == nil
                         ? L10n.text("条数过大，请输入更小的数字。")
                         : L10n.text("请输入大于 0 的整数。"))
                        .font(Typo.paneCaption).foregroundStyle(Theme.danger)
                }
                HStack(spacing: Space.m) {
                    Toggle(L10n.text("保存图片"), isOn: $forward.draft.saveImages)
                        .toggleStyle(SettingsOptionToggleStyle(symbol: "photo"))
                        .accessibilityIdentifier("moments.images")
                    Toggle(L10n.text("保存视频"), isOn: $forward.draft.saveVideos)
                        .toggleStyle(SettingsOptionToggleStyle(symbol: "video"))
                        .accessibilityIdentifier("moments.videos")
                }
                if forward.draft.saveImages || forward.draft.saveVideos {
                    Label(forward.draft.saveVideos
                          ? L10n.text("保存视频会非常慢，请耐心等待。")
                          : L10n.text("保存图片会非常慢，请耐心等待。"), systemImage: "clock")
                        .font(Typo.paneCaption).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.disabled(forward.isBusy)

            SettingsSection(title: L10n.text("粘贴到"), systemImage: "arrow.up.forward.app", spacing: Space.m) {
                QuickForwardDestinationPicker(
                    targetBundleIdentifier: forward.draft.targetBundleIdentifier,
                    targetName: forward.draft.targetName,
                    folder: forward.draft.destinationFolder,
                    applications: forward.applications,
                    pastePath: $forward.draft.pastePath,
                    onChooseApplication: forward.chooseTarget,
                    onChooseFolder: forward.chooseFolder,
                    onRefresh: forward.refreshApplications,
                    identifierPrefix: "moments"
                )
            }.disabled(forward.isBusy)

            if forward.draft.destinationFolder == nil {
                SettingsSection(title: L10n.text("附加 Prompt"), systemImage: "text.quote", spacing: Space.m) {
                    PromptSettingsView(preferences: preferences, surface: .moments, compact: true)
                }.disabled(forward.isBusy)
            }
            if !authorization.isTrusted {
                Notice(text: L10n.text("朋友圈转发需要辅助功能权限。"), tone: .warn) {
                    Button(L10n.text("开启权限")) { authorization.guideIfNeeded() }.buttonStyle(SettingsActionButtonStyle())
                }
            }
            if let error = forward.error { Notice(error, tone: .bad) }
            QuickForwardFooter(
                isBusy: forward.isBusy,
                canRun: forward.canRun,
                savesToFolder: forward.draft.destinationFolder != nil,
                status: forward.status,
                elapsedSeconds: forward.elapsedSeconds,
                identifierPrefix: "moments",
                onStart: { forward.start() },
                onCancel: { forward.cancel() }
            )
        }
        .onAppear {
            amount = forward.draft.count > 0 ? String(forward.draft.count) : ""
            forward.refreshApplications()
        }
    }
}
