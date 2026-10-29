import AppKit
import DukouCore
import SwiftUI
import UniformTypeIdentifiers

/// The app half of `ShareEntryList`: one 「发给 <app>」 per row of the user's
/// list, and the only place that list is edited.
///
/// Each row is an app, a switch for its own entry in the Share menu — generated
/// on this Mac so it shows the app's icon (`DirectShareEntries`) — and the
/// paste mode. The same list is what 「发送到自定义」 asks from, in this order,
/// and what both 发给 ▸ menus show, which is why the rows can be dragged.
struct AppEntryList: View {
    @ObservedObject var targets: ForwardTargets
    let spacing: CGFloat
    let editable: Bool

    /// The guide has room for a few rows and a footer, not for a long list.
    private static let guideRows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if editable {
                if !targets.isEmpty { reorderable }
                AddForwardTargetButton(targets: targets)
            } else {
                ForEach(targets.targets.prefix(Self.guideRows)) { target in
                    AppEntryRow(target: target, targets: targets, editable: false)
                }
            }
            if let error = targets.directShareError {
                Notice(error)
            }
        }
    }

    private var rowHeight: CGFloat { AppEntryRow.height + spacing }

    /// A `List` rather than the `VStack` the rows above sit in: it is the only
    /// container that gives `onMove` a real drag-to-reorder on macOS. Each row
    /// carries the stack's spacing inside its own height, and the list gives
    /// half of it back at either end, so the gaps match the rows above.
    private var reorderable: some View {
        List {
            ForEach(targets.targets) { target in
                AppEntryRow(target: target, targets: targets, editable: true)
                    .frame(height: rowHeight)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .onMove { targets.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .environment(\.defaultMinListRowHeight, 0)
        .frame(height: rowHeight * CGFloat(targets.targets.count))
        .padding(.vertical, -spacing / 2)
        // The table under a macOS `List` insets its rows even with zero row
        // insets: measured 8 pt leading and 9 pt trailing on macOS 27. Given
        // back, so icons and switches line up with the rows above.
        .padding(.leading, -8)
        .padding(.trailing, -9)
    }
}

/// One 「发给 <app>」: laid out like the built-in entries above it, with the
/// app's own icon where they have a symbol.
struct AppEntryRow: View {
    let target: ForwardTarget
    @ObservedObject var targets: ForwardTargets
    var editable = true

    static let iconSize: CGFloat = 20
    static let removeWidth = SettingsControlMetrics.height
    /// A title line and a detail line, as `SettingRow` draws them.
    static let height: CGFloat = 38

    @State private var hovering = false

    var body: some View {
        let installed = InstalledApp.lookup(target.bundleIdentifier)

        HStack(alignment: .center, spacing: Space.m) {
            Image(nsImage: installed.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize + 2, height: Self.iconSize + 2)
                .frame(width: Self.iconSize)
                .accessibilityHidden(true)

            // One line each: the list's rows have a fixed height, and a long
            // English name would otherwise wrap into the next row.
            SettingRow(title: title, detail: detail(installed: installed.isInstalled), alignment: .center) {
                HStack(spacing: Space.m) {
                    // Said out loud rather than left to fail at forward time:
                    // the app may have been uninstalled since it was added, and
                    // the only place that can be noticed calmly is here.
                    if !installed.isInstalled {
                        StatusPill(text: L10n.text("未安装"), tone: .warn)
                            .fixedSize()
                    }
                    if editable { pathOnlyToggle }
                    entrySwitch(installed: installed.isInstalled)
                    if editable { removeButton }
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.horizontal, isHighlighted ? Space.s : 0)
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isHighlighted ? Theme.accentSoft : .clear)
                .padding(.vertical, -Space.xs)
        )
        .onHover { hovering = $0 }
        .animation(Motion.reduced(Motion.ui), value: isHighlighted)
        // Contained, not combined: the row holds several controls, and folding
        // them into one element would leave VoiceOver switches it can read but
        // not flip.
        .accessibilityElement(children: .contain)
    }

    /// The name the Share menu shows, so the row and the menu read alike.
    private var title: String {
        DirectShareEntryName.title(for: target.displayName, chinese: L10n.locale().identifier.hasPrefix("zh"))
    }

    private func detail(installed: Bool) -> String {
        target.pastesPathOnly
            ? L10n.format("激活 %@ 并粘贴文件路径。", target.displayName)
            : L10n.format("激活 %@ 并粘贴文件。", target.displayName)
    }

    /// The answer to "I clicked add and nothing happened": the app was already
    /// in the list, and this is the row that says so.
    private var isHighlighted: Bool { targets.highlighted == target.id }

    /// Always visible, not only on hover: it decides whether a terminal gets
    /// anything from the forward at all, and the detail line says which way it
    /// is set.
    private var pathOnlyToggle: some View {
        Toggle(isOn: Binding(
            get: { target.pastesPathOnly },
            set: { targets.setPastesPathOnly($0, for: target) }
        )) {
            Text(L10n.text("只粘贴文件路径"))
                .font(Typo.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
        .toggleStyle(CheckboxToggleStyle())
        .fixedSize()
        .help(L10n.text("给终端类应用用：粘贴的是带引号的文件路径，跟把文件拖进终端一样。"))
    }

    /// An entry needs the app to take its icon from, so a missing app's switch
    /// can be turned off but not on.
    private func entrySwitch(installed: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { target.showsInShareMenu },
            set: { targets.setShowsInShareMenu($0, for: target) }
        )) {
            Text(title)
        }
        .toggleStyle(SwitchToggleStyle())
        .labelsHidden()
        .frame(width: SwitchToggleStyle.width)
        .disabled(!installed && !target.showsInShareMenu)
        .help(L10n.format("在微信「选择电脑中的应用」里显示「%@」。关掉后仍能从暂存架和记录发给它；「−」才是移除。", title))
    }

    private var removeButton: some View {
        Button { targets.remove(target) } label: {
            Image(systemName: "minus")
        }
        .buttonStyle(IconButtonStyle(size: Self.removeWidth, staticFeedback: true))
        .help(L10n.text("移除"))
        .accessibilityLabel(Text(L10n.format("移除 %@", target.displayName)))
        .opacity(hovering ? 1 : 0.4)
    }
}

/// Running apps are directly visible, with a pinned Finder action below them.
private struct AddForwardTargetButton: View {
    @ObservedObject var targets: ForwardTargets
    @State private var applications: [RunningApp] = []
    @State private var expanded = false
    @State private var pendingFinder = false
    @FocusState private var focused: Bool
    private static let finderAction = "choose-from-finder"

    var body: some View {
        Button {
            applications = targets.runningApplications()
            expanded.toggle()
        } label: {
            Label(L10n.text("添加其他应用"), systemImage: "plus")
        }
        .buttonStyle(SettingsActionButtonStyle())
        .focused($focused)
        .focusEffectDisabled()
        .modifier(SettingsFocusRing(focused: focused))
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            SettingsChoiceList(
                title: L10n.text("运行中的应用程序"), selection: "",
                choices: applications.map { .init(id: $0.id, title: $0.name, image: $0.icon) },
                identifier: "entries.add",
                disabledValues: Set(targets.targets.map(\.bundleIdentifier)),
                footer: .init(id: Self.finderAction, title: L10n.text("手动从访达中选择…"), symbol: "folder")
            ) { id in
                if id == Self.finderAction {
                    pendingFinder = true
                } else if let app = applications.first(where: { $0.id == id }) {
                    targets.add(bundleIdentifier: app.id, displayName: app.name)
                }
                expanded = false
            } dismiss: {
                expanded = false
            }
            .frame(width: 320)
            .onDisappear {
                // Still inside the popover's teardown and a CA commit here,
                // where AppKit suppresses runModal; open the panel a turn later.
                guard pendingFinder else { return }
                pendingFinder = false
                DispatchQueue.main.async { chooseFromFinder() }
            }
        }
        .onChange(of: expanded) { _, value in if !value { focused = true } }
        .accessibilityIdentifier("entries.add")
    }

    private func chooseFromFinder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default
            .urls(for: .applicationDirectory, in: .localDomainMask)
            .first
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { targets.add(applicationAt: url) }
    }
}
