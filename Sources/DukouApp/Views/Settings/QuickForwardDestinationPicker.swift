import DukouCore
import SwiftUI

/// Shared by quick-forward surfaces. Choosing a destination belongs to the
/// caller, so cancelling its folder panel never changes this selection.
struct QuickForwardDestinationPicker: View {
    let targetBundleIdentifier: String
    let targetName: String
    let folder: URL?
    let applications: [RunningApp]
    @Binding var pastePath: Bool
    let onChooseApplication: (String) -> Void
    let onChooseFolder: () -> Void
    let onRefresh: () -> Void
    let identifierPrefix: String

    @State private var hoveringFolder = false
    @FocusState private var folderFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                HStack(spacing: Space.s) {
                    SettingsSelect(
                        title: L10n.text("正在运行的应用"),
                        selection: Binding(get: { folder == nil ? targetBundleIdentifier : "" }, set: onChooseApplication),
                        choices: applications.map { .init(id: $0.id, title: $0.name, image: $0.icon) },
                        identifier: identifierPrefix + ".target",
                        placeholder: folder != nil || targetName.isEmpty
                            ? L10n.text("选择应用")
                            : L10n.format("%@（未运行）", targetName)
                    )
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle(size: SettingsControlMetrics.height, staticFeedback: true))
                        .help(L10n.text("刷新运行中的应用"))
                        .accessibilityLabel(Text(L10n.text("刷新运行中的应用")))
                        .accessibilityIdentifier(identifierPrefix + ".refresh")
                }
                .frame(maxWidth: .infinity)

                Text(L10n.text("或"))
                    .font(Typo.paneCaption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize()
                    .accessibilityIdentifier(identifierPrefix + ".destinationOr")

                Button(action: onChooseFolder) {
                    HStack(spacing: Space.s) {
                        Image(systemName: "folder").accessibilityHidden(true)
                        Text(folder.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
                             ?? L10n.text("指定文件夹"))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if folder != nil {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                    }
                    .font(SettingsControlMetrics.font)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, SettingsControlMetrics.inset)
                    .frame(height: SettingsControlMetrics.height)
                    .background(hoveringFolder && isEnabled ? Theme.hover : Theme.sunken,
                                in: RoundedRectangle(cornerRadius: SettingsControlMetrics.radius))
                    .overlay {
                        RoundedRectangle(cornerRadius: SettingsControlMetrics.radius)
                            .strokeBorder(folder == nil ? Theme.strokeStrong : Theme.ink, lineWidth: Stroke.hairline)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: SettingsControlMetrics.radius))
                    .opacity(isEnabled ? 1 : 0.45)
                }
                .buttonStyle(PlainPressButtonStyle(staticFeedback: true))
                .frame(maxWidth: .infinity)
                .focused($folderFocused)
                .focusEffectDisabled()
                .modifier(SettingsFocusRing(focused: folderFocused))
                .onHover { hoveringFolder = $0 }
                .help(folder?.path ?? L10n.text("指定文件夹"))
                .accessibilityLabel(Text(L10n.text("指定文件夹")))
                .accessibilityValue(Text(folder?.path ?? ""))
                .accessibilityAddTraits(folder == nil ? [] : [.isSelected])
                .accessibilityIdentifier(identifierPrefix + ".folder")
            }

            SettingsChoiceStrip(
                title: L10n.text("粘贴方式"),
                selection: Binding(get: { folder == nil && pastePath }, set: { pastePath = folder == nil && $0 }),
                choices: [
                    .init(id: false, title: L10n.text("粘贴文件"), symbol: "doc"),
                    .init(id: true, title: L10n.text("粘贴路径"), symbol: "link"),
                ]
            )
            .disabled(folder != nil)
            .accessibilityIdentifier(identifierPrefix + ".pasteMode")

            Text(folder == nil
                 ? L10n.text("请先点选目标应用的输入框。")
                 : L10n.text("ZIP 保存到此文件夹，同名文件自动改名。"))
                .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
