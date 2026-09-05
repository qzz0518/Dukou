import DukouCore
import SwiftUI

struct GeneralPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var updater: AppUpdater
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            SettingsSection(title: L10n.text("启动"), systemImage: "power") {
                SettingRow(
                    title: L10n.text("登录时自动启动"),
                    detail: L10n.text("开机后静默出现在菜单栏，转发和暂存架才会立刻响应。"),
                    alignment: .center
                ) {
                    // The title stays on the control for VoiceOver and is then
                    // hidden visually; an empty label would leave the switch
                    // unnamed.
                    Toggle(L10n.text("登录时自动启动"), isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    ))
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
                }

                if loginItem.needsApproval {
                    Notice(text: L10n.text("还需要在系统设置里允许。"), tone: .warn) {
                        Button(L10n.text("打开登录项设置")) { LoginItem.openLoginItemsSettings() }
                            .buttonStyle(SettingsActionButtonStyle())
                    }
                }
                if let error = loginItem.lastError {
                    Notice(error, tone: .bad)
                }
            }

            SettingsSection(title: L10n.text("暂存架"), systemImage: "tray") {
                SettingRow(
                    title: L10n.text("停靠位置"),
                    detail: L10n.text("暂存架出现时停在这个角落；拖到别处后会记住，直到你再改这里。"),
                    alignment: .center
                ) {
                    SettingsSelect(
                        title: L10n.text("停靠位置"), selection: $preferences.shelfCorner,
                        choices: [
                            .init(id: .topLeft, title: L10n.text("左上"), symbol: "arrow.up.left"),
                            .init(id: .topRight, title: L10n.text("右上"), symbol: "arrow.up.right"),
                            .init(id: .bottomLeft, title: L10n.text("左下"), symbol: "arrow.down.left"),
                            .init(id: .bottomRight, title: L10n.text("右下"), symbol: "arrow.down.right"),
                        ], identifier: "general.corner"
                    )
                    .frame(width: SettingsControlMetrics.actionWidth)
                }

                // Only for a shelf that has actually been dragged: an escape
                // hatch offered to someone who has never left the corner is a
                // button whose effect they cannot see.
                if preferences.shelfAnchor != nil {
                    HStack {
                        Spacer(minLength: 0)
                        Button(L10n.text("重置位置")) { actions.forgetShelfAnchor() }
                            .buttonStyle(SettingsActionButtonStyle())
                            .help(L10n.text("忘记拖动过的位置"))
                    }
                }
            }

            SettingsSection(title: L10n.text("记录"), systemImage: "clock.arrow.circlepath") {
                SettingRow(
                    title: L10n.text("自动清理"),
                    detail: L10n.text("不在暂存架上的记录，超过这个时长自动移到废纸篓。"),
                    alignment: .center
                ) {
                    SettingsSelect(
                        title: L10n.text("自动清理"), selection: $preferences.historyRetentionDays,
                        choices: [
                            .init(id: 1, title: L10n.text("1 天")),
                            .init(id: 7, title: L10n.text("7 天")),
                            .init(id: 30, title: L10n.text("30 天")),
                            .init(id: 0, title: L10n.text("从不")),
                        ], identifier: "general.retention"
                    )
                    .frame(width: SettingsControlMetrics.actionWidth)
                }
            }

            // The same section AutoCodeBar has, in the same place: the switch
            // Sparkle reads for its daily check, and the version with a way to
            // check right now. 关于 repeats the button beside the version pill.
            SettingsSection(title: L10n.text("软件更新"), systemImage: "arrow.triangle.2.circlepath") {
                SettingRow(
                    title: L10n.text("自动检查更新"),
                    detail: L10n.text("每天检查一次，由 Sparkle 安全下载并安装。"),
                    alignment: .center
                ) {
                    Toggle(L10n.text("自动检查更新"), isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
                }

                SettingRow(
                    title: L10n.text("当前版本"),
                    detail: AppVersion.short + " (" + AppVersion.build + ")",
                    alignment: .center
                ) {
                    Button(L10n.text("检查更新…")) { updater.checkForUpdates() }
                        .buttonStyle(SettingsActionButtonStyle())
                        .disabled(!updater.canCheckForUpdates)
                }
            }

            SettingsSection(title: L10n.text("设置向导"), systemImage: "sparkles") {
                SettingRow(
                    title: L10n.text("重新运行设置向导"),
                    detail: L10n.text("四步走一遍：入口、暂存架、权限、完成。"),
                    alignment: .center
                ) {
                    Button(L10n.text("重新运行")) { actions.restartOnboarding() }
                        .buttonStyle(SettingsActionButtonStyle())
                }
            }
        }
    }
}
