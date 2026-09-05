import AppKit
import DukouCore
import SwiftUI
import UniformTypeIdentifiers

/// The first run, in the order Dukou is actually adopted: switch on an entry,
/// learn what the shelf does, hand over the one permission, done.
///
/// A window of its own rather than a pane in 设置, because none of this is a
/// setting. Dukou's whole surface lives inside WeChat's Share menu and on a
/// floating square that only appears once something has arrived — neither can be
/// demonstrated by a settings window, and a user who never finds the entries
/// never sees the app work at all.
///
/// Every step is laid out to fit without scrolling. A guide whose next button is
/// below the fold is a guide people abandon, so anything that does not fit is a
/// cue to cut the copy rather than to add a `ScrollView`.
struct OnboardingFlow: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var authorization: AccessibilityAuthorization
    /// Closes the guide. `openSettings` is the only thing the last step can ask
    /// for beyond that.
    let finish: (_ openSettings: Bool) -> Void

    /// One probe for the whole guide, and the very same list the 入口 pane
    /// draws — §11.2 asks for one implementation of these switches, not two.
    @StateObject private var probe = ShareEntryProbe()
    @State private var step: Step

    init(
        preferences: Preferences,
        authorization: AccessibilityAuthorization,
        finish: @escaping (_ openSettings: Bool) -> Void
    ) {
        self.preferences = preferences
        self.authorization = authorization
        self.finish = finish
        _step = State(initialValue: Step(rawValue: preferences.onboardingStep) ?? .entries)
    }

    enum Step: Int, CaseIterable {
        case entries, shelf, permissions, done

        var title: String {
            switch self {
            case .entries: L10n.text("入口")
            case .shelf: L10n.text("暂存架")
            case .permissions: L10n.text("权限")
            case .done: L10n.text("完成")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StepBar(steps: Step.allCases.map(\.title), current: step.rawValue)
                .frame(height: 52)
                .padding(.top, 6)
                .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Theme.stroke)
                .frame(height: Stroke.hairline)

            HStack(spacing: 0) {
                art
                    .frame(width: Metrics.onboardingArtWidth)
                    .frame(maxHeight: .infinity)
                // In light appearance the aurora fades to almost the same grey
                // as the content pane by the bottom of the column, and the two
                // halves of the window ran together. One hairline is cheaper
                // than making the gradient louder.
                Rectangle()
                    .fill(Theme.stroke)
                    .frame(width: Stroke.hairline)
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: Metrics.onboardingWidth, height: Metrics.onboardingHeight)
        .background(Theme.raised)
        .onAppear {
            authorization.refresh()
            probe.refresh()
            preferences.onboardingStep = step.rawValue
        }
        .onChange(of: step) { _, new in preferences.onboardingStep = new.rawValue }
        // The permission is granted, and the entries can be switched, in System
        // Settings — in another process, while this window waits. Both have to
        // be re-read the moment the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            authorization.refresh()
            probe.refresh()
        }
        .animation(Motion.reduced(.easeInOut(duration: 0.22)), value: step)
    }

    // MARK: - Art column

    private var art: some View {
        ZStack {
            AuroraBackdrop()
            Group {
                switch step {
                case .entries: ShareMenuArt()
                case .shelf: ShelfArt()
                case .permissions: PermissionArt()
                // The same menu step 1 promised, now as the thing to go and
                // look for. It is the one picture the last step's sentence is
                // actually about.
                case .done: ShareMenuArt()
                }
            }
            .frame(width: Metrics.onboardingArtContentWidth)
        }
    }

    // MARK: - Steps

    private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .entries: entriesStep
            case .shelf: shelfStep
            case .permissions: permissionsStep
            case .done: doneStep
            }
            // Every step but the last is read top-down. The last one is a full
            // stop, and a full stop belongs in the middle of the pane rather
            // than pinned under a step bar it no longer belongs to.
            if step != .done { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
    }

    private var entriesStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(
                title: L10n.text("把微信的转发菜单接到你要去的地方"),
                subtitle: L10n.text("把微信里的聊天记录压缩包接住，再拖给任何一个 App。")
            )

            ShareEntryList(probe: probe, spacing: Space.m)
                .padding(.top, 20)

            Text(L10n.text("以后随时能在设置 → 入口 里改。"))
                .font(Typo.paneCaption)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.top, 14)

            StepFooter(next: (L10n.text("继续"), { step = .shelf }))
                .padding(.top, 20)
        }
    }

    private var shelfStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(
                title: L10n.text("暂存到渡口，再拖到任何地方"),
                subtitle: L10n.text("用「暂存到渡口」转发过来的文件，都停在这个方块上。")
            )

            VStack(alignment: .leading, spacing: 16) {
                bullet(
                    "square.stack.3d.up",
                    L10n.text("可以叠加：连续暂存几次，都会摞在同一个架子上，右上角的数字就是件数。")
                )
                bullet(
                    "hand.draw",
                    L10n.text("拖出去就送达：把图标拖进任何 App 或文件夹，文件就过去了，架子随之清空；文件本身还留在「记录」里。")
                )
                bullet(
                    "xmark.circle",
                    L10n.text("✕ 移出架子，⌄ 展开成列表逐个拖；右键还能直接发给 Codex / Claude。")
                )
            }
            .padding(.top, 26)

            StepFooter(
                back: (L10n.text("上一步"), { step = .entries }),
                next: (L10n.text("继续"), { step = .permissions })
            )
            .padding(.top, 30)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: L10n.text("让 Dukou 代你按 ⌘V"))

            ChecklistRow(
                done: authorization.isTrusted,
                title: L10n.text("辅助功能"),
                detail: L10n.text("用于操作微信，以及激活目标应用并粘贴；只暂存或复制不需要。")
            ) {
                if !authorization.isTrusted {
                    Button(L10n.text("引导授权")) { authorization.guideIfNeeded() }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            .padding(.top, 26)

            Text(L10n.text("可以先跳过，第一次转发失败时 Dukou 会再引导一次。"))
                .font(Typo.paneCaption)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.top, 14)

            StepFooter(
                back: (L10n.text("上一步"), { step = .shelf }),
                // The button says what pressing it means. "继续" over an
                // unfinished permission would read as "and that's handled".
                next: (
                    authorization.isTrusted ? L10n.text("继续") : L10n.text("稍后再说"),
                    { step = .done }
                )
            )
            .padding(.top, 30)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Theme.positiveSoft)
                    .frame(width: 64, height: 64)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityHidden(true)

            Text(L10n.text("好了"))
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 24)

            Text(L10n.text("去微信多选聊天记录 → 转发到其他应用，就能看到这些入口了。"))
                .font(.system(size: 15))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            HStack(spacing: Space.m) {
                Button(L10n.text("开始使用")) { finish(false) }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button(L10n.text("打开设置")) { finish(true) }
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(.top, 34)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Step furniture

private struct StepTitle: View {
    let title: String
    /// Absent where the step's own content already says it: a subtitle that
    /// paraphrases the line under it is one more thing to read, not one more
    /// thing to know.
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                // Wraps rather than being pinned to one line: the English copy
                // is half again as long as the Chinese, and a title that has to
                // fit one line is a title written to fit one language.
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 500, alignment: .leading)
    }
}

/// Back on the left, forward on the right, Return always on forward.
private struct StepFooter: View {
    var back: (title: String, action: () -> Void)?
    let next: (title: String, action: () -> Void)

    var body: some View {
        HStack(spacing: Space.m) {
            if let back {
                Button(back.title, action: back.action)
                    .buttonStyle(GhostButtonStyle())
            }
            Button(next.title, action: next.action)
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Art

/// What the Share menu will look like once the switches above are on. Drawn
/// rather than screenshotted, because a screenshot of someone else's menu ages
/// the moment they restyle it.
private struct ShareMenuArt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("转发到其他应用"))
                .font(Typo.captionStrong)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            ForEach(ShareAction.allCases, id: \.self) { action in
                HStack(spacing: 10) {
                    Image(systemName: ShareEntryList.symbol(for: action))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                    Text(action.entryTitle)
                        .font(Typo.paneBody)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: Stroke.hairline)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        .accessibilityHidden(true)
    }
}

/// The shelf, drawn at the size it really is, with an arrow out of it. The one
/// thing a first run cannot show for real: the shelf only exists once something
/// has arrived, and nothing has yet.
private struct ShelfArt: View {
    private static let side: CGFloat = 150
    private static let iconSide: CGFloat = 72

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            shelf
            arrow
            destinations
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var shelf: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.strokeStrong)
                .frame(width: Metrics.shelfGripSize.width, height: Metrics.shelfGripSize.height)
                .padding(.top, 9)

            Spacer(minLength: 0)
            stack
            Spacer(minLength: 0)

            Text(L10n.text("聊天记录.zip"))
                .font(Typo.micro)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.selected, in: Capsule())
                .padding(.bottom, 12)
        }
        .frame(width: Self.side, height: Self.side)
        // Opaque, not `.regularMaterial`. A material takes its colour from what
        // is behind it, and what is behind it here is the aurora: measured in
        // dark, the square's inside came out (34,56,49) against a neighbouring
        // (28,57,49) — 1.05:1, a square that was only its own hairline. The
        // three destination tiles beside it are `Theme.raised` and read as
        // solid objects, so the drawing put its subject behind its supporting
        // cast. Material is for the real panel, which floats over other
        // people's windows; a drawing of it is a drawing.
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Radius.shelf, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.shelf, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: Stroke.hairline)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }

    /// Same shoulders, same rotation, same green badge as the real thing —
    /// copied from `ShelfView` so what the guide promises is what arrives.
    private var stack: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                fileIcon
                    .rotationEffect(.degrees(Double(index + 1) * -4))
                    .offset(x: CGFloat(index + 1) * -5, y: CGFloat(index + 1) * 3)
                    .opacity(0.55)
            }
            fileIcon
            Text(verbatim: "3")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.accent, in: Capsule())
                .offset(x: Self.iconSide / 2 - 2, y: -Self.iconSide / 2 + 4)
        }
    }

    /// The zip icon Launch Services would hand back for a real chat export,
    /// rather than a drawn rectangle that resembles one.
    private var fileIcon: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: .zip))
            .resizable()
            .frame(width: Self.iconSide, height: Self.iconSide)
    }

    private var arrow: some View {
        HStack(spacing: 2) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 6))
                path.addLine(to: CGPoint(x: 18, y: 6))
            }
            // `strokeStrong` is a border token and disappeared into the
            // aurora; the arrow is the one line in the drawing that has to be
            // followed, so it borrows text ink instead.
            .stroke(
                Theme.inkSecondary,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2.5, 4])
            )
            .frame(width: 18, height: 12)
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 8))
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private var destinations: some View {
        VStack(spacing: 10) {
            tile("folder.fill", L10n.text("Finder"))
            tile("terminal.fill", L10n.text("终端"))
            tile("bubble.left.fill", L10n.text("Claude"))
        }
    }

    private func tile(_ symbol: String, _ name: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 30, height: 30)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: Stroke.hairline)
                )
            Text(name)
                .font(Typo.micro)
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// The pitfall of this particular permission, said once, beside the row that
/// asks for it: macOS never prompts for Accessibility, so a user waiting for a
/// dialog waits forever.
private struct PermissionArt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "hand.raised.slash")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(L10n.text("辅助功能不会弹系统授权框，需要把 Dukou 拖进列表；授权后立即生效，不必重启。"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: Stroke.hairline)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        .accessibilityHidden(true)
    }
}
