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
        }
        .onAppear { probe.refresh() }
        // The entries can still be changed in System Settings, and the user
        // comes straight back afterwards, so this is re-read on every
        // activation rather than once.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            probe.refresh()
        }
    }
}
