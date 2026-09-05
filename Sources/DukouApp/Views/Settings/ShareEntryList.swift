import DukouCore
import SwiftUI

/// The Share-menu entries, one switch each.
///
/// Lives on its own because two places need exactly this list: the 入口 pane and
/// step 1 of the first-run guide. A second copy would be a second answer to
/// "what does this switch do", and they would drift the first time one of them
/// was touched.
struct ShareEntryList: View {
    @ObservedObject var probe: ShareEntryProbe
    /// Tighter in the first-run guide, where five rows and a footer have to fit
    /// one unscrollable screen.
    var spacing: CGFloat = Space.l

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(ShareAction.allCases, id: \.self) { row($0) }

            if probe.hasUnregisteredEntry {
                Notice(L10n.text("Dukou 需要安装在「应用程序」文件夹里，系统才会登记这些入口。"))
            }
        }
    }

    private func row(_ action: ShareAction) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            Image(systemName: Self.symbol(for: action))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
                .accessibilityHidden(true)

            SettingRow(title: action.entryTitle, detail: Self.detail(for: action), alignment: .center) {
                control(for: action)
            }
        }
    }

    /// Until the first read lands there is nothing honest to draw, so the row
    /// shows a spinner in the switch's place. Once it has, the switch stays on
    /// screen for good: a click moves it at once, the election is read back
    /// behind it — a second click meanwhile is ignored by the probe, and there
    /// is no spinner for those few milliseconds, the user asked for none —
    /// and a refusal moves it back, animated.
    @ViewBuilder
    private func control(for action: ShareAction) -> some View {
        if probe.state(of: action) == nil {
            ProgressView()
                .controlSize(.small)
                // The width of the switch it stands in for, so the row does not
                // reflow when the answer arrives.
                .frame(width: Self.switchWidth)
        } else if probe.state(of: action) == .unregistered {
            HStack(spacing: Space.s) {
                StatusPill(text: L10n.text("未注册"), tone: .neutral)
                entrySwitch(action)
                    .disabled(true)
            }
        } else {
            entrySwitch(action)
        }
    }

    private func entrySwitch(_ action: ShareAction) -> some View {
        Toggle(isOn: Binding(
            get: { probe.isOn(action) },
            set: { probe.setEnabled($0, for: action) }
        )) {
            // Hidden on screen, read aloud by VoiceOver: without it the switch
            // announces itself as an unnamed control four times over.
            Text(action.entryTitle)
        }
        .toggleStyle(SwitchToggleStyle())
        .labelsHidden()
        .frame(width: Self.switchWidth)
    }

    private static let switchWidth = SwitchToggleStyle.width

    /// Not private: the guide's art column draws the same menu, and a second
    /// table of symbols would be a second answer to "which icon is this entry".
    static func symbol(for action: ShareAction) -> String {
        switch action {
        case .shelf: "tray.and.arrow.down"
        case .codex, .claude: "paperplane"
        case .clipboard: "doc.on.clipboard"
        case .custom: "paperplane.circle"
        }
    }

    private static func detail(for action: ShareAction) -> String {
        switch action {
        case .shelf: L10n.text("放到暂存架，自己拖到任何 App。")
        case .codex: L10n.text("激活 ChatGPT 并直接粘贴到输入框。")
        case .claude: L10n.text("激活 Claude 并直接粘贴到输入框。")
        case .clipboard: L10n.text("只放进剪贴板，去哪儿按 ⌘V 由你决定。")
        case .custom: L10n.text("转发时从你自己的清单里挑一个 App，激活它并粘贴。")
        }
    }
}
