import DukouCore
import SwiftUI

/// The 附加 Prompt controls: one switch per surface, with a shared library
/// and selection across forwarding pages.
struct PromptSettingsView: View {
    @ObservedObject var preferences: Preferences
    let surface: PromptSurface
    /// Quick exports keep the editor out of the way until attachment is on.
    var compact = false

    var body: some View {
        // The section header already says 附加 Prompt, so the switch carries
        // the sentence rather than a bold title repeating the header.
        HStack(alignment: .center, spacing: Space.l) {
            Text(switchDetail)
                .font(Typo.paneCaption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.m)
            Toggle(switchDetail, isOn: Binding(
                get: { isEnabled },
                set: { setEnabled($0) }
            ))
            .toggleStyle(SwitchToggleStyle())
            .labelsHidden()
            .accessibilityLabel(Text(switchDetail))
        }

        if !compact || isEnabled {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach($preferences.prompt.prompts) { $prompt in
                    PromptRow(
                        prompt: $prompt,
                        isSelected: preferences.prompt.selectedID == prompt.id,
                        select: { preferences.prompt.selectedID = prompt.id },
                        remove: { preferences.prompt.remove(id: prompt.id) }
                    )
                }
                HStack(alignment: .center, spacing: Space.m) {
                    Text(L10n.text("选中的那条会被附加，最多 3 条，各转发页面共用。"))
                        .font(Typo.paneCaption)
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.m)
                    Button {
                        preferences.prompt.add(AttachedPrompt(text: ""))
                    } label: {
                        Label(L10n.text("添加 Prompt"), systemImage: "plus")
                    }
                    .buttonStyle(SettingsActionButtonStyle())
                    .disabled(!preferences.prompt.canAdd)
                }
            }
        }
    }

    private var isEnabled: Bool {
        switch surface {
        case .forward: return preferences.prompt.attachToForwards
        case .wechat: return preferences.prompt.attachToWeChat
        case .moments: return preferences.prompt.attachToMoments
        }
    }

    private func setEnabled(_ enabled: Bool) {
        switch surface {
        case .forward: preferences.prompt.attachToForwards = enabled
        case .wechat: preferences.prompt.attachToWeChat = enabled
        case .moments: preferences.prompt.attachToMoments = enabled
        }
    }

    private var switchDetail: String {
        if compact { return L10n.text("把选中的 Prompt 一起粘贴。") }
        switch surface {
        case .forward:
            return L10n.text("发给 Codex、Claude 或自定义应用时，把选中的 Prompt 一起粘过去。")
        case .wechat, .moments:
            return L10n.text("导出的记录粘贴到目标应用时，把选中的 Prompt 一起粘过去。")
        }
    }
}

/// One prompt: pick it, write it, or drop it.
private struct PromptRow: View {
    @Binding var prompt: AttachedPrompt
    let isSelected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Button(action: select) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.inkTertiary)
                    .frame(width: 24, height: SettingsControlMetrics.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("使用这条 Prompt"))
            .accessibilityLabel(Text(L10n.text("使用这条 Prompt")))

            TextField(L10n.text("Prompt 内容"), text: $prompt.text, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(SettingsTextFieldStyle(multiline: true))

            Button(action: remove) {
                Image(systemName: "minus")
            }
            .buttonStyle(IconButtonStyle(size: SettingsControlMetrics.height, staticFeedback: true))
            .help(L10n.text("删除这条 Prompt"))
            .accessibilityLabel(Text(L10n.text("删除这条 Prompt")))
        }
        .padding(Space.s + 2)
        .background(
            isSelected ? Theme.accentSoft : Theme.sunken,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}
