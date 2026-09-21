import DukouCore
import SwiftUI

/// The 附加 Prompt controls: one switch per surface, with a shared library
/// and selection across forwarding pages.
struct PromptSettingsView: View {
    @ObservedObject var preferences: Preferences
    let surface: PromptSurface
    /// Quick exports keep the editor out of the way until attachment is on.
    var compact = false
    /// The group 快捷微信转发 is filled in for. With one, picking a prompt is
    /// remembered for that group alone — including when it is forwarded by
    /// hand — and the selection everything else follows is left as it was.
    var chat = ""

    var body: some View {
        // 入口 has room to say what the switch does. A quick forward page puts
        // the switch on the section's title line instead — see
        // `QuickForwardPromptSection` — and shows nothing until it is on.
        if !compact {
            HStack(alignment: .center, spacing: Space.l) {
                Text(switchDetail)
                    .font(Typo.paneCaption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.m)
                Toggle(switchDetail, isOn: Self.isEnabled(preferences, surface))
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
                    .accessibilityLabel(Text(switchDetail))
            }
        }

        if !compact || Self.isEnabled(preferences, surface).wrappedValue {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach($preferences.prompt.prompts) { $prompt in
                    PromptRow(
                        prompt: $prompt,
                        isSelected: selectedID == prompt.id,
                        select: { select(prompt.id) },
                        remove: {
                            preferences.prompt.remove(id: prompt.id)
                            preferences.chatMemory.forget(prompt: prompt.id)
                        }
                    )
                }
                HStack(alignment: .center, spacing: Space.m) {
                    Text(remembersChat ? L10n.text("所选 Prompt 只对这个群生效。") : L10n.text("最多 3 条，各转发页面共用。"))
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
                if surface != .moments {
                    HStack(alignment: .center, spacing: Space.s) {
                        Text(L10n.text("续聊"))
                            .font(Typo.paneBodyStrong)
                            .foregroundStyle(Theme.ink)
                        Text(L10n.text("同一个群再次发送时，只处理上次之后的新消息。"))
                            .font(Typo.paneCaption)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Space.m)
                        Toggle(L10n.text("续聊"), isOn: $preferences.prompt.resumesChats)
                            .toggleStyle(SwitchToggleStyle())
                            .labelsHidden()
                    }
                    .padding(.top, Space.xs)
                }
            }
        }
    }

    static func isEnabled(_ preferences: Preferences, _ surface: PromptSurface) -> Binding<Bool> {
        Binding(
            get: {
                switch surface {
                case .forward: preferences.prompt.attachToForwards
                case .wechat: preferences.prompt.attachToWeChat
                case .moments: preferences.prompt.attachToMoments
                }
            },
            set: {
                switch surface {
                case .forward: preferences.prompt.attachToForwards = $0
                case .wechat: preferences.prompt.attachToWeChat = $0
                case .moments: preferences.prompt.attachToMoments = $0
                }
            }
        )
    }

    private var remembersChat: Bool { !ChatMemories.key(chat).isEmpty }

    /// The chat's own prompt while it still exists, else the shared selection.
    private var selectedID: UUID? {
        guard remembersChat, let id = preferences.chatMemory.promptID(for: chat),
              preferences.prompt.prompts.contains(where: { $0.id == id }) else { return preferences.prompt.selectedID }
        return id
    }

    private func select(_ id: UUID) {
        if remembersChat {
            preferences.chatMemory.setPrompt(id, for: chat)
        } else {
            preferences.prompt.selectedID = id
        }
    }

    private var switchDetail: String {
        switch surface {
        case .forward:
            return L10n.text("发给 Codex、Claude 或自定义应用时，把选中的 Prompt 一起粘过去。")
        case .wechat, .moments:
            return L10n.text("导出的记录粘贴到目标应用时，把选中的 Prompt 一起粘过去。")
        }
    }
}

/// 附加 Prompt on a quick forward page: the switch rides on the title line, and
/// the library appears under it only while it is on.
struct QuickForwardPromptSection: View {
    @ObservedObject var preferences: Preferences
    let surface: PromptSurface
    var chat = ""

    var body: some View {
        SettingsSection(title: L10n.text("附加 Prompt"), systemImage: "text.quote", spacing: Space.m, accessory: {
            Toggle(L10n.text("附加 Prompt"), isOn: PromptSettingsView.isEnabled(preferences, surface))
                .toggleStyle(SwitchToggleStyle())
                .labelsHidden()
        }) {
            PromptSettingsView(preferences: preferences, surface: surface, compact: true, chat: chat)
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
