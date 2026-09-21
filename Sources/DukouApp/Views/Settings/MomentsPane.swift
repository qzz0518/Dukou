import DukouCore
import SwiftUI

struct MomentsPane: View {
    @ObservedObject var forward: MomentsQuickForward
    @ObservedObject var authorization: AccessibilityAuthorization
    @ObservedObject var preferences: Preferences
    @State private var amount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if !authorization.isTrusted {
                Notice(text: L10n.text("朋友圈转发需要辅助功能权限。"), tone: .warn) {
                    Button(L10n.text("开启权限")) { authorization.guideIfNeeded() }.buttonStyle(SettingsActionButtonStyle())
                }
            }
            WeChatInterfaceNotice(authorization: authorization)

            SettingsSection(title: L10n.text("转发内容"), systemImage: "photo.on.rectangle.angled", spacing: Space.m) {
                FormRow(L10n.text("范围")) {
                    VStack(alignment: .leading, spacing: Space.s) {
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
                        }
                        if !forward.draft.isValid {
                            Text(!amount.isEmpty && Int(amount) == nil
                                 ? L10n.text("条数过大，请输入更小的数字。")
                                 : L10n.text("请输入大于 0 的整数。"))
                                .font(Typo.paneCaption).foregroundStyle(Theme.danger)
                        }
                    }
                }
                FormRow(L10n.text("附带")) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: Space.s) {
                            Toggle(L10n.text("图片"), isOn: $forward.draft.saveImages)
                                .accessibilityIdentifier("moments.images")
                            Toggle(L10n.text("视频"), isOn: $forward.draft.saveVideos)
                                .accessibilityIdentifier("moments.videos")
                        }
                        .toggleStyle(SettingsChipToggleStyle())
                        if forward.draft.saveImages || forward.draft.saveVideos {
                            Label(forward.draft.saveVideos
                                  ? L10n.text("保存视频会非常慢。")
                                  : L10n.text("保存图片会非常慢。"), systemImage: "clock")
                                .font(Typo.paneCaption).foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }.disabled(forward.isBusy)

            SettingsSection(title: L10n.text("送到"), systemImage: "arrow.up.forward.app", spacing: Space.m) {
                QuickForwardDestinationPicker(
                    targetBundleIdentifier: forward.draft.targetBundleIdentifier,
                    targetName: forward.draft.targetName,
                    folder: forward.draft.destinationFolder,
                    applications: forward.applications,
                    pastePath: $forward.draft.pastePath,
                    onChooseApplication: forward.chooseTarget,
                    onChooseFolder: forward.chooseFolder,
                    onShowApplications: forward.showApplications,
                    onShowFolder: forward.showFolder,
                    onRefresh: forward.refreshApplications,
                    identifierPrefix: "moments"
                )
            }.disabled(forward.isBusy)

            if forward.draft.destinationFolder == nil {
                QuickForwardPromptSection(preferences: preferences, surface: .moments)
                    .disabled(forward.isBusy)
            }
        }
        .onAppear {
            amount = forward.draft.count > 0 ? String(forward.draft.count) : ""
            forward.refreshApplications()
        }
    }
}
