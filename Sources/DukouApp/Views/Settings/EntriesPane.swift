import AppKit
import DukouCore
import SwiftUI

/// What the Share menu offers, and the switches that decide which of it shows.
///
/// The list itself is fixed at build time — macOS builds that menu from signed
/// extension bundles — but which entries are live is the user's call, and it is
/// made here rather than three panes deep in System Settings. See
/// `ShareEntryProbe` for why the app is not sandboxed.
struct EntriesPane: View {
    @ObservedObject var targets: ForwardTargets
    @ObservedObject var preferences: Preferences
    @StateObject private var probe = ShareEntryProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            Text(L10n.text("微信「转发到其他应用」里出现哪些入口，这里说了算。关掉的那条立刻从菜单里消失。"))
                .font(Typo.paneBody)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                // The same measure the 关于 pane's prose uses. Left uncapped it
                // ran the full 512 pt column while identical type three panes
                // away stopped 50 pt short.
                .frame(maxWidth: 460, alignment: .leading)

            SettingsSection(title: L10n.text("转发菜单里的入口"), systemImage: "square.and.arrow.up") {
                ShareEntryList(probe: probe)

                // Kept only as a way back to the system's own list — Dukou's
                // switches write the same setting, so this is a bystander, not
                // an instruction.
                Notice(text: L10n.text("也可以在「系统设置 → 登录项与扩展 → 共享」里管理。")) {
                    Button(L10n.text("打开系统设置")) { LoginItem.openExtensionsSettings() }
                        .buttonStyle(SettingsActionButtonStyle())
                }
            }

            SettingsSection(title: L10n.text("「发送到自定义」的应用"), systemImage: "arrow.up.forward.app") {
                ForwardTargetList(targets: targets)
            }

            SettingsSection(title: L10n.text("附加 Prompt"), systemImage: "text.quote") {
                PromptSettingsView(preferences: preferences, surface: .forward)
            }

            SettingsSection(title: L10n.text("怎么用"), systemImage: "hand.point.up.left", spacing: Space.m) {
                step(
                    1,
                    title: L10n.text("打开要用的入口"),
                    detail: L10n.text("上面那几个开关，拨一下就生效，随时能再改。")
                )
                step(
                    2,
                    title: L10n.text("从微信转发"),
                    detail: L10n.text("多选聊天记录 → 转发到其他应用 → 选你要的那一条。")
                )
                step(
                    3,
                    title: L10n.text("剩下的交给 Dukou"),
                    detail: L10n.text("转发类入口会自己激活目标 App 并粘贴；「暂存到渡口」会把文件放到屏幕角落的暂存架，拖走就消失。")
                )
            }
        }
        .onAppear { probe.refresh() }
        // The entries can still be changed in System Settings, and the user
        // comes straight back afterwards, so this is re-read on every
        // activation rather than once.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            probe.refresh()
        }
    }

    private func step(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text(verbatim: "\(number)")
                .font(Font.numeral(11, .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 20, height: 20)
                .background(Theme.sunken, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typo.paneBodyStrong)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(Typo.paneCaption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
