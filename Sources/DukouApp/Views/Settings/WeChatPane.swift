import AppKit
import DukouCore
import SwiftUI

struct WeChatPane: View {
    @ObservedObject var forward: WeChatQuickForward
    @ObservedObject var authorization: AccessibilityAuthorization
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(L10n.text("选择微信群和消息范围，自动合并为微信原生 ZIP，粘贴到你正在使用的应用。"))
                .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsSection(title: L10n.text("转发内容"), systemImage: "bubble.left.and.bubble.right", spacing: Space.m) {
                HStack(spacing: Space.s) {
                    TextField(L10n.text("微信群名称"), text: $forward.draft.chat)
                        .textFieldStyle(SettingsTextFieldStyle())
                        .accessibilityIdentifier("wechat.chat")
                    Button(L10n.text("读取当前群")) { forward.readCurrentChat() }
                        .buttonStyle(SettingsActionButtonStyle())
                        .fixedSize()
                        .disabled(forward.isReadingChat)
                }
                HStack(spacing: Space.s) {
                    Text(L10n.text("最近")).font(Typo.paneBody)
                    TextField(L10n.text("范围数量"), value: $forward.draft.range.value, format: .number.grouping(.never))
                        .textFieldStyle(SettingsTextFieldStyle(numeric: true, invalid: !forward.draft.range.isValid))
                        .multilineTextAlignment(.center)
                        .frame(width: 64)
                        .accessibilityIdentifier("wechat.amount")
                        .disabled(forward.draft.range.unit != .messages)
                    Text(forward.draft.range.unit.title)
                        .font(Typo.paneBody)
                        .accessibilityIdentifier("wechat.unit")
                    if forward.draft.range.unit != .messages {
                        Button(L10n.text("改用条数")) { forward.useMessageCount() }
                            .buttonStyle(SettingsActionButtonStyle())
                            .accessibilityIdentifier("wechat.useMessageCount")
                    }
                    Spacer(minLength: 0)
                }
                Text(forward.draft.range.unit == .messages
                     ? L10n.text("按最新消息向前选取，每个 ZIP 最多 100 条；一次任务最多 2,000 条。")
                     : L10n.text("按时间选取暂未开放，请改用条数。"))
                    .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !forward.draft.range.isValid {
                    Text(L10n.format("请输入 1–%d 之间的整数。", forward.draft.range.unit.maximum))
                        .font(Typo.paneCaption).foregroundStyle(Theme.danger)
                }
            }.disabled(forward.isBusy)

            SettingsSection(title: L10n.text("粘贴到"), systemImage: "arrow.up.forward.app", spacing: Space.m) {
                HStack(spacing: Space.s) {
                    SettingsSelect(
                        title: L10n.text("正在运行的应用"),
                        selection: Binding(get: { forward.draft.targetBundleIdentifier }, set: { forward.chooseTarget($0) }),
                        choices: forward.applications.map { .init(id: $0.id, title: $0.name, image: $0.icon) },
                        identifier: "wechat.target",
                        placeholder: forward.draft.targetName.isEmpty
                            ? L10n.text("选择正在运行的应用")
                            : L10n.format("%@（未运行）", forward.draft.targetName)
                    )
                    Button { forward.refreshApplications() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle(size: SettingsControlMetrics.height, staticFeedback: true))
                        .help(L10n.text("刷新运行中的应用"))
                        .accessibilityLabel(Text(L10n.text("刷新运行中的应用")))
                        .accessibilityIdentifier("wechat.refresh")
                }
                SettingsChoiceStrip(
                    title: L10n.text("粘贴方式"), selection: $forward.draft.pastePath,
                    choices: [
                        .init(id: false, title: L10n.text("粘贴文件"), symbol: "doc"),
                        .init(id: true, title: L10n.text("粘贴路径"), symbol: "link"),
                    ]
                )
                .accessibilityIdentifier("wechat.pasteMode")
                Text(L10n.text("请先在目标应用中选好输入位置。完成后自动按 ⌘V，成功执行的群聊和配置会被记住。"))
                    .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.disabled(forward.isBusy)

            SettingsSection(title: L10n.text("附加 Prompt"), systemImage: "text.quote", spacing: Space.m) {
                PromptSettingsView(preferences: preferences, surface: .wechat)
            }.disabled(forward.isBusy)

            if !authorization.isTrusted {
                Notice(text: L10n.text("微信转发需要辅助功能权限。"), tone: .warn) {
                    Button(L10n.text("开启权限")) { authorization.guideIfNeeded() }.buttonStyle(SettingsActionButtonStyle())
                }
            }
            if let error = forward.error { Notice(error, tone: .bad) }
            HStack(alignment: .center, spacing: Space.l) {
                if let status = forward.status {
                    HStack(alignment: .top, spacing: Space.s) {
                        if forward.isBusy { ProgressView().controlSize(.small) }
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(status).font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("wechat.status")
                            if let elapsed = forward.elapsedSeconds, !forward.isBusy {
                                Text(L10n.format("%.1f 秒", elapsed)).font(Typo.paneCaption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                if forward.isBusy {
                    Button(L10n.text("取消")) { forward.cancel() }.buttonStyle(SettingsActionButtonStyle())
                        .fixedSize()
                        .accessibilityIdentifier("wechat.cancel")
                } else {
                    Button(L10n.text("开始转发")) { forward.start() }.buttonStyle(SettingsActionButtonStyle(primary: true))
                        .fixedSize()
                        .disabled(!forward.canRun)
                        .accessibilityIdentifier("wechat.run")
                }
            }

            if !forward.recent.isEmpty {
                SettingsSection(title: L10n.text("记住的群聊"), systemImage: "clock.arrow.circlepath", spacing: Space.m) {
                    ForEach(forward.recent) { preset in
                        HStack(spacing: Space.s) {
                            Button { forward.use(preset) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.chat).font(Typo.rowTitle).foregroundStyle(Theme.ink)
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(preset.range.title + " · " + preset.targetName + " · " + (preset.pastePath ? L10n.text("粘贴路径") : L10n.text("粘贴文件")))
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
}
