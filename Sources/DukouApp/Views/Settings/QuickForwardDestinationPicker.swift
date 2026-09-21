import DukouCore
import SwiftUI

/// Shared by quick-forward surfaces. An app or a folder is one choice, so it is
/// made first and only the controls that choice uses are shown under it: a
/// paste mode means nothing to a folder, and a file format nothing to an app.
///
/// Choosing a destination belongs to the caller, so cancelling its folder panel
/// never changes this selection — the strip simply stays where it was.
struct QuickForwardDestinationPicker: View {
    let targetBundleIdentifier: String
    let targetName: String
    let folder: URL?
    let applications: [RunningApp]
    @Binding var pastePath: Bool
    /// Whether the folder receives an unpacked Markdown note instead of the
    /// ZIP. Nil where there is no such format to offer.
    var markdown: Binding<Bool>?
    let onChooseApplication: (String) -> Void
    let onChooseFolder: () -> Void
    let onShowApplications: () -> Void
    let onShowFolder: () -> Void
    let onRefresh: () -> Void
    let identifierPrefix: String

    @State private var hoveringFolder = false
    @FocusState private var folderFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SettingsChoiceStrip(
                title: L10n.text("送到"),
                selection: Binding(get: { folder != nil }, set: { $0 ? onShowFolder() : onShowApplications() }),
                choices: [
                    .init(id: false, title: L10n.text("应用"), symbol: "macwindow"),
                    .init(id: true, title: L10n.text("文件夹"), symbol: "folder"),
                ]
            )
            .accessibilityIdentifier(identifierPrefix + ".destination")

            if let folder {
                FormRow(L10n.text("位置")) { folderButton(folder) }
                if let markdown {
                    FormRow(L10n.text("格式")) {
                        SettingsChoiceStrip(
                            title: L10n.text("格式"),
                            selection: markdown,
                            choices: [
                                .init(id: false, title: "ZIP", symbol: "archivebox"),
                                .init(id: true, title: L10n.text("Markdown 文件夹"), symbol: "doc.plaintext"),
                            ]
                        )
                        .accessibilityIdentifier(identifierPrefix + ".format")
                    }
                }
                caption(markdown?.wrappedValue == true
                        ? L10n.text("存成文件夹：Markdown 笔记加附件，可直接放进 Obsidian。")
                        : L10n.text("ZIP 保存到此文件夹，同名文件自动改名。"))
            } else {
                FormRow(L10n.text("应用")) {
                    HStack(spacing: Space.s) {
                        SettingsSelect(
                            title: L10n.text("正在运行的应用"),
                            selection: Binding(get: { targetBundleIdentifier }, set: onChooseApplication),
                            choices: applications.map { .init(id: $0.id, title: $0.name, image: $0.icon) },
                            identifier: identifierPrefix + ".target",
                            placeholder: targetName.isEmpty ? L10n.text("选择应用") : L10n.format("%@（未运行）", targetName)
                        )
                        Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(IconButtonStyle(size: SettingsControlMetrics.height, staticFeedback: true))
                            .help(L10n.text("刷新运行中的应用"))
                            .accessibilityLabel(Text(L10n.text("刷新运行中的应用")))
                            .accessibilityIdentifier(identifierPrefix + ".refresh")
                    }
                }
                FormRow(L10n.text("粘贴")) {
                    SettingsChoiceStrip(
                        title: L10n.text("粘贴方式"),
                        selection: $pastePath,
                        choices: [
                            .init(id: false, title: L10n.text("文件"), symbol: "doc"),
                            .init(id: true, title: L10n.text("路径"), symbol: "link"),
                        ]
                    )
                    .accessibilityIdentifier(identifierPrefix + ".pasteMode")
                }
                caption(L10n.text("请先点选目标应用的输入框。"))
            }
        }
    }

    /// Under the rows' controls rather than under their labels.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typo.paneCaption).foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, FormRow<EmptyView>.contentInset)
    }

    private func folderButton(_ folder: URL) -> some View {
        Button(action: onChooseFolder) {
            HStack(spacing: Space.s) {
                Image(systemName: "folder").accessibilityHidden(true)
                Text(folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("更改…")).foregroundStyle(Theme.inkSecondary)
            }
            .font(SettingsControlMetrics.font)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, SettingsControlMetrics.inset)
            .frame(height: SettingsControlMetrics.height)
            .background(hoveringFolder && isEnabled ? Theme.hover : Theme.sunken,
                        in: RoundedRectangle(cornerRadius: SettingsControlMetrics.radius))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsControlMetrics.radius)
                    .strokeBorder(Theme.strokeStrong, lineWidth: Stroke.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: SettingsControlMetrics.radius))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(PlainPressButtonStyle(staticFeedback: true))
        .focused($folderFocused)
        .focusEffectDisabled()
        .modifier(SettingsFocusRing(focused: folderFocused))
        .onHover { hoveringFolder = $0 }
        .help(folder.path)
        .accessibilityLabel(Text(L10n.text("指定文件夹")))
        .accessibilityValue(Text(folder.path))
        .accessibilityIdentifier(identifierPrefix + ".folder")
    }
}
