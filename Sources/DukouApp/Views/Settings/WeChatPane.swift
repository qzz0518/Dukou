import AppKit
import DukouCore
import SwiftUI

struct WeChatPane: View {
    @ObservedObject var forward: WeChatQuickForward
    @ObservedObject var authorization: AccessibilityAuthorization
    @ObservedObject var preferences: Preferences
    /// The amount field's own text, so a rejected keystroke can be taken back.
    @State private var amount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            // What stops a run is said before the form, not under it.
            if !authorization.isTrusted {
                Notice(text: L10n.text("微信转发需要辅助功能权限。"), tone: .warn) {
                    Button(L10n.text("开启权限")) { authorization.guideIfNeeded() }.buttonStyle(SettingsActionButtonStyle())
                }
            }
            WeChatInterfaceNotice(authorization: authorization)

            SettingsSection(title: L10n.text("转发内容"), systemImage: "bubble.left.and.bubble.right", spacing: Space.m) {
                FormRow(L10n.text("群聊")) {
                    HStack(spacing: Space.s) {
                        TextField(L10n.text("微信群名称"), text: $forward.draft.chat)
                            .textFieldStyle(SettingsTextFieldStyle())
                            .accessibilityIdentifier("wechat.chat")
                        Button(L10n.text("读取当前群")) { forward.readCurrentChat() }
                            .buttonStyle(SettingsActionButtonStyle())
                            .fixedSize()
                            .disabled(forward.isReadingChat)
                    }
                }
                FormRow(L10n.text("范围")) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: Space.s) {
                            Text(L10n.text("最近")).font(Typo.paneBody)
                            // A TextField will not take a correction back from its own
                            // binding while it has focus, so the field owns its text and
                            // the count follows it. Anything that is not a digit is
                            // removed on the keystroke that typed it.
                            TextField(L10n.text("范围数量"), text: $amount)
                                .textFieldStyle(SettingsTextFieldStyle(numeric: true, invalid: !forward.draft.range.isValid))
                                .multilineTextAlignment(.center)
                                .frame(width: min(176, max(64, CGFloat(amount.count) * 8 + 24)))
                                .accessibilityIdentifier("wechat.amount")
                                .disabled(forward.draft.range.unit != .messages)
                                .onChange(of: amount) { _, typed in
                                    let digits = WeChatForwardRange.digits(typed)
                                    if digits != typed { amount = digits }
                                    forward.setAmount(digits)
                                }
                                .onChange(of: forward.draft.range.unit) { _, _ in
                                    // Switching a legacy time preset to messages replaces
                                    // the amount from outside the field.
                                    amount = forward.amountText
                                }
                                .onChange(of: forward.draft.range.value) { _, value in
                                    // A remembered preset can replace the count without
                                    // changing units. Preserve empty or overflowing text
                                    // while editing; both already map to the invalid zero.
                                    if (Int(amount) ?? 0) != value { amount = forward.amountText }
                                }
                                .onAppear { amount = forward.amountText }
                            Text(forward.draft.range.unit.title)
                                .font(Typo.paneBody)
                                .accessibilityIdentifier("wechat.unit")
                            if forward.draft.range.unit != .messages {
                                Button(L10n.text("改用条数")) { forward.useMessageCount() }
                                    .buttonStyle(SettingsActionButtonStyle())
                                    .accessibilityIdentifier("wechat.useMessageCount")
                            }
                            Spacer(minLength: Space.s)
                            if let estimate = forward.draft.range.estimatedTimeTitle {
                                Text(estimate)
                                    .font(Typo.paneCaption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("wechat.estimate")
                            }
                        }
                        if forward.draft.range.unit != .messages {
                            Text(L10n.text("按时间选取暂未开放，请改用条数。"))
                                .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !forward.draft.range.isValid {
                            Text(rangeValidationMessage)
                                .font(Typo.paneCaption).foregroundStyle(Theme.danger)
                        }
                    }
                }
                FormRow(L10n.text("附带")) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: Space.s) {
                            Toggle(L10n.text("图片"), isOn: $forward.draft.saveImages)
                                .accessibilityIdentifier("wechat.images")
                            Toggle(L10n.text("视频"), isOn: $forward.draft.saveVideos)
                                .accessibilityIdentifier("wechat.videos")
                            Toggle(L10n.text("HTML 预览"), isOn: $forward.draft.htmlPreview)
                                .help(L10n.text("解压后打开 index.html，按时间线查看聊天记录。"))
                                .accessibilityIdentifier("wechat.htmlPreview")
                            // WeChat exports a hundred messages at a time, so up
                            // to that there is one ZIP and nothing to merge; and
                            // a Markdown note is one note whatever this says.
                            if forward.draft.range.value > 100, !forward.draft.savesMarkdown {
                                Toggle(L10n.text("合并为一个 ZIP"), isOn: $forward.draft.mergeArchives)
                                    .accessibilityIdentifier("wechat.mergeArchives")
                            }
                        }
                        .toggleStyle(SettingsChipToggleStyle())
                        if forward.draft.recommendsMergingArchives {
                            Label(L10n.text("消息较多，建议合并以减少附件数量。"), systemImage: "lightbulb")
                                .font(Typo.paneCaption).foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("wechat.mergeRecommendation")
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
                    markdown: $forward.draft.markdown,
                    onChooseApplication: forward.chooseTarget,
                    onChooseFolder: forward.chooseFolder,
                    onShowApplications: forward.showApplications,
                    onShowFolder: forward.showFolder,
                    onRefresh: forward.refreshApplications,
                    identifierPrefix: "wechat"
                )
            }.disabled(forward.isBusy)

            if forward.draft.destinationFolder == nil {
                QuickForwardPromptSection(preferences: preferences, surface: .wechat, chat: forward.draft.chat)
                    .disabled(forward.isBusy)
            }

            if !forward.recent.isEmpty {
                SettingsSection(title: L10n.text("记住的群聊"), systemImage: "clock.arrow.circlepath", spacing: Space.m) {
                    ForEach(forward.recent) { preset in
                        HStack(spacing: Space.s) {
                            Button { forward.use(preset) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.chat).font(Typo.rowTitle).foregroundStyle(Theme.ink)
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(preset.range.title + " · " + (preset.destinationFolder?.path ?? preset.targetName) + " · " +
                                         (preset.destinationFolder != nil ? L10n.text("保存文件") : (preset.pastePath ? L10n.text("粘贴路径") : L10n.text("粘贴文件"))))
                                        .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(PlainPressButtonStyle(staticFeedback: true))
                            Button(L10n.text("再次执行")) { forward.start(preset) }.buttonStyle(SettingsActionButtonStyle())
                                .fixedSize()
                                .disabled(!preset.range.isAvailableForAutomation)
                            Button { forward.forget(preset) } label: { Image(systemName: "xmark") }
                                .buttonStyle(IconButtonStyle(size: SettingsControlMetrics.height, staticFeedback: true)).help(L10n.text("忘记这个群聊"))
                                .accessibilityLabel(Text(L10n.text("忘记这个群聊")))
                        }
                    }
                }.disabled(forward.isBusy)
            }
        }
        .onAppear { forward.refreshApplications() }
    }

    private var rangeValidationMessage: String {
        guard forward.draft.range.unit == .messages else {
            return L10n.format("请输入 1–%d 之间的整数。", forward.draft.range.unit.maximum)
        }
        return !amount.isEmpty && Int(amount) == nil
            ? L10n.text("条数过大，请输入更小的数字。")
            : L10n.text("请输入大于 0 的整数。")
    }
}

/// Says that this WeChat account shows Dukou no controls before the form is
/// filled in, rather than after a run has failed on it. Shared by both quick
/// forward panes; silent whenever WeChat cannot be judged.
struct WeChatInterfaceNotice: View {
    @ObservedObject var authorization: AccessibilityAuthorization
    @State private var isHidden = false

    var body: some View {
        Group {
            if isHidden { Notice(WeChatAutomationError.interfaceHidden.localizedDescription, tone: .warn) }
        }
        .task(id: authorization.isTrusted) { await probe() }
        // Logging in to WeChat, or switching accounts, happens over there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await probe() }
        }
    }

    private func probe() async {
        isHidden = await Task.detached { WeChatAccessibility.interfaceVisibility() == .hidden }.value
    }
}
