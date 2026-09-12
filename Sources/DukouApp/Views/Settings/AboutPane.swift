import AppKit
import DukouCore
import SwiftUI

/// The version out of the bundle. A plain `swift run` build has no Info.plist at
/// all, so both fields carry a placeholder rather than crashing the pane.
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}

struct AboutPane: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Dukou（渡口）")
                        .font(Typo.paneTitle)
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: Space.s) {
                        StatusPill(text: L10n.format("版本 %@ (%@)", AppVersion.short, AppVersion.build))
                        // Disabled while Sparkle is already busy, not while the
                        // bundle has no feed: a `swift run` build simply never
                        // enables it, which is the honest state of that build.
                        Button(L10n.text("检查更新…")) { updater.checkForUpdates() }
                            .buttonStyle(SettingsActionButtonStyle())
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
            }

            SettingsSection(title: L10n.text("Dukou 做什么"), systemImage: "info.circle", spacing: 10) {
                paragraph(L10n.text("在微信的转发菜单里，直接把聊天记录送到你要用的地方。"))
                paragraph(L10n.text("也是聊天记录与朋友圈的本地备份工具：导出只走微信自带的转发和朋友圈界面，不读数据库、不解密、不注入。"))
                paragraph(L10n.text("聊天文件在本机处理，渡口不会上传聊天内容。文件会按清理设置保留，可随时在「记录」中管理。"))
            }

            SettingsSection(title: L10n.text("链接"), systemImage: "link") {
                SettingRow(title: L10n.text("源码与问题反馈"), detail: "GitHub", alignment: .center) {
                    Button { AppLinks.open(AppLinks.github) } label: {
                        Label(L10n.text("打开"), systemImage: "arrow.up.right")
                    }
                        .buttonStyle(SettingsActionButtonStyle())
                        .accessibilityLabel(Text(L10n.text("源码与问题反馈")))
                }

                SettingRow(title: L10n.text("作者"), detail: "X · @zerah_eth", alignment: .center) {
                    Button { AppLinks.open(AppLinks.x) } label: {
                        Label(L10n.text("打开"), systemImage: "arrow.up.right")
                    }
                        .buttonStyle(SettingsActionButtonStyle())
                        .accessibilityLabel(Text(verbatim: "X · @zerah_eth"))
                }
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(Typo.paneBody)
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460, alignment: .leading)
    }
}
