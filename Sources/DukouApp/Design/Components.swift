import DukouCore
import SwiftUI

// MARK: - Page skeleton

/// A titled block: a quiet label, one rule, then rows. Whitespace separates the
/// rows; the line under the label is the only divider a settings group needs.
struct SettingsSection<Content: View>: View {
    let title: String
    var systemImage: String?
    var spacing: CGFloat = Space.l
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Text(title)
                    .font(Typo.sectionLabel)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.bottom, Space.s)

            Rectangle()
                .fill(Theme.stroke)
                .frame(height: Stroke.hairline)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Title and explanation on the left, one control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var alignment: VerticalAlignment = .top
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: alignment, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typo.rowTitle)
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(Typo.paneCaption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.m)
            control()
        }
    }
}

extension SettingRow where Control == EmptyView {
    init(title: String, detail: String? = nil, alignment: VerticalAlignment = .top) {
        self.init(title: title, detail: detail, alignment: alignment, control: { EmptyView() })
    }
}

/// A soft filled block for explanations and summaries.
struct Panel<Content: View>: View {
    var padding: CGFloat = Space.l
    var tone: Color = Theme.sunken
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// One line of advice: an icon, a sentence, coloured by severity, with an
/// optional trailing control.
///
/// A notice that names a problem carries the button that fixes it. Splitting the
/// two — a warning here, its remedy three lines down — is how a settings pane
/// ends up with three layouts for one idea.
struct Notice<Trailing: View>: View {
    enum Tone { case info, good, warn, bad }

    let text: String
    var tone: Tone = .info
    var systemImage: String?
    @ViewBuilder var trailing: () -> Trailing

    private var colors: (fore: Color, back: Color, icon: String) {
        switch tone {
        case .info: (Theme.inkSecondary, Theme.sunken, "info.circle")
        case .good: (Theme.positive, Theme.positiveSoft, "checkmark.circle")
        case .warn: (Theme.warning, Theme.warningSoft, "exclamationmark.triangle")
        case .bad: (Theme.danger, Theme.dangerSoft, "exclamationmark.octagon")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage ?? colors.icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(colors.fore)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.paneCaption)
                .foregroundStyle(tone == .info ? Theme.inkSecondary : colors.fore)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.m)
            trailing()
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 10)
        .background(colors.back, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

extension Notice where Trailing == EmptyView {
    init(_ text: String, tone: Tone = .info, systemImage: String? = nil) {
        self.init(text: text, tone: tone, systemImage: systemImage, trailing: { EmptyView() })
    }
}

// MARK: - Buttons

/// Shared press feedback. Large/static artwork can opt out; Reduce Motion
/// keeps every control still while its fill continues to show the press.
struct ButtonPressFeedback: ViewModifier {
    let isPressed: Bool
    var staticFeedback = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && isEnabled && !staticFeedback && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion || staticFeedback ? nil : Motion.ui, value: isPressed)
    }
}

struct PlainPressButtonStyle: ButtonStyle {
    var staticFeedback = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ButtonPressFeedback(isPressed: configuration.isPressed, staticFeedback: staticFeedback))
    }
}

/// The primary action: a high-contrast pill, black on light and white on dark.
struct InkButtonStyle: ButtonStyle {
    var wide = false
    var staticFeedback = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            // Dimming a high-contrast pill only leaves a noisy grey slab. A
            // disabled primary action should fall back to the level of the card
            // it sits on.
            .foregroundStyle(isEnabled ? Theme.onFill : Theme.inkTertiary)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(isEnabled ? Theme.fill : Theme.sunken, in: Capsule(style: .continuous))
            .opacity(isEnabled && configuration.isPressed ? 0.78 : 1)
            .contentShape(Capsule())
            .animation(Motion.reduced(Motion.ui), value: configuration.isPressed)
            .modifier(ButtonPressFeedback(isPressed: configuration.isPressed, staticFeedback: staticFeedback))
    }
}

/// The secondary action: an outlined pill on the page ground.
struct GhostButtonStyle: ButtonStyle {
    var wide = false
    var staticFeedback = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(configuration.isPressed ? Theme.hover : Theme.surface, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: Stroke.hairline))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Capsule())
            .modifier(ButtonPressFeedback(isPressed: configuration.isPressed, staticFeedback: staticFeedback))
    }
}

/// The third-level action inside a card: filled, borderless, compact.
///
/// One step *above* whatever it sits on, plus an edge. The reference's
/// `Theme.sunken` only ever sat on `raised`; Dukou also puts these buttons on
/// the 记录 pane's sunken row cards, where the fill and the card were the same
/// token and the capsule disappeared entirely — measured at (28,28,31) on
/// (28,28,31) in dark. The hairline is what keeps it a control on any ground.
struct SoftButtonStyle: ButtonStyle {
    var tone: Color = Theme.hover
    var foreground: Color = Theme.ink
    var staticFeedback = false
    var minHeight: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minHeight: minHeight)
            .background(configuration.isPressed ? Theme.selected : tone, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.stroke, lineWidth: Stroke.hairline))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Capsule())
            .modifier(ButtonPressFeedback(isPressed: configuration.isPressed, staticFeedback: staticFeedback))
    }
}

/// Icon-only actions in a card's corner.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var staticFeedback = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.inkSecondary)
            .frame(width: size, height: size)
            .background(Circle().fill(configuration.isPressed ? Theme.selected : Color.clear))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Circle())
            .modifier(ButtonPressFeedback(isPressed: configuration.isPressed, staticFeedback: staticFeedback))
    }
}

// MARK: - Switch

/// The switch, drawn rather than tinted. The same control as AutoCodeBar's
/// `DrawnSwitchToggleStyle`, which is the reference for Dukou's settings.
///
/// Drawn because `.toggleStyle(.switch).tint(...)` does not hold its colour in
/// dark appearance: measured 2026-09-05 on the signed build, a tinted track
/// came back at roughly 30 % over the pane, 1.8:1 against the unlit one, and a
/// pane of five switches was legible only by knob position. The track is
/// therefore painted here in both appearances: the brand green when on, the
/// system's grey when off, a knob that travels.
struct SwitchToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// NSSwitch's own regular-size metrics, so a Dukou switch is the same object
    /// the rest of macOS uses.
    static let width: CGFloat = 38
    private static let height: CGFloat = 22
    private static let knob: CGFloat = 18
    private static let inset: CGFloat = 2
    /// How far the knob travels from one end to the other.
    private static let travel = width - knob - inset * 2
    /// The unlit track is dark in dark appearance, so the knob on it has to be
    /// lighter than the track without being the on-state's pure white.
    private static let unlitKnob = Color.dynamic(light: 0xFFFFFF, dark: 0xC9C9CF)

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        let animation = Motion.reduced(Motion.ui, reduceMotion)
        Button {
            // Explicit: the binding writes into a model and flows back into
            // the view, and an implicit animation does not always catch that.
            withAnimation(animation) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: .leading) {
                // A round knob on a round-ended track; a continuous-corner
                // capsule comes out squarer than the knob at both ends.
                Capsule()
                    .fill(isOn ? Theme.controlOn : Theme.strokeStrong)
                    .frame(width: Self.width, height: Self.height)
                Circle()
                    .fill(isOn ? Color.white : Self.unlitKnob)
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.20), radius: 1, y: 0.5)
                    // An offset, not a ZStack alignment: an offset is an
                    // animatable quantity, an alignment is not.
                    .offset(x: Self.inset + (isOn ? Self.travel : 0))
            }
            .contentShape(Capsule())
            // On the label, not on the Button. Measured 2026-09-06 with six
            // variants side by side and a 30 ms frame grab: an
            // `.animation(value:)` on the Button never reaches the label on
            // macOS — the knob jumped in every one of those variants, a plain
            // `@State` binding included — while the same modifier here
            // animates the knob and the track colour.
            .animation(animation, value: isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        // The drawn track has no semantics of its own. The system switch is
        // rebuilt here for VoiceOver only — never rendered — so the control
        // still announces itself as a switch carrying the caller's label.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Checkbox

/// The checkbox, drawn for the reason the switch is: the system one fills with
/// whatever accent the user picked in System Settings, and a pane whose
/// switches are Dukou's green should not tick its boxes in somebody else's
/// blue.
struct CheckboxToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    private static let side: CGFloat = 14
    private static let corner: CGFloat = 3.5

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Space.xs + 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .fill(configuration.isOn ? Theme.controlOn : Color.clear)
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .strokeBorder(
                            configuration.isOn ? Color.clear : Theme.strokeStrong,
                            lineWidth: Stroke.hairline
                        )
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.onFill)
                    }
                }
                .frame(width: Self.side, height: Self.side)
                configuration.label
            }
            .contentShape(Rectangle())
            // Inside the label for the reason the switch's is: on the Button
            // it never runs.
            .animation(Motion.reduced(Motion.ui), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        // Drawn box, system semantics: VoiceOver reads a checkbox with the
        // caller's label, never the button underneath.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}

// MARK: - Status

struct StatusPill: View {
    enum Tone { case neutral, live, warn, bad }

    let text: String
    var tone: Tone = .neutral

    private var color: Color {
        switch tone {
        case .neutral: Theme.inkSecondary
        case .live: Theme.positive
        case .warn: Theme.warning
        case .bad: Theme.danger
        }
    }

    /// The neutral ground is `selected`, not `sunken`: the 记录 rows are sunken
    /// cards, and a sunken pill on them drew no capsule at all — 已送达 read as
    /// bare text beside a 在暂存架上 that had one, which made two of six records
    /// look styled and the rest unfinished.
    private var background: Color {
        switch tone {
        case .neutral: Theme.selected
        case .live: Theme.positiveSoft
        case .warn: Theme.warningSoft
        case .bad: Theme.dangerSoft
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
                .fixedSize()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(background, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One permission: a status pill on the right, and the button that fixes it only
/// when something is missing.
struct PermissionRow<Action: View>: View {
    let title: String
    let detail: String
    let granted: Bool
    var grantedText: String = L10n.text("已授权")
    var missingText: String = L10n.text("未授权")
    var missingTone: StatusPill.Tone = .warn
    @ViewBuilder let action: () -> Action

    var body: some View {
        SettingRow(title: title, detail: detail, alignment: .center) {
            HStack(spacing: Space.s) {
                StatusPill(
                    text: granted ? grantedText : missingText,
                    tone: granted ? .live : missingTone
                )
                if !granted {
                    action()
                }
            }
        }
    }
}

/// The round translucent buttons on the shelf. Named, because `.help()` is a
/// tooltip and VoiceOver never reads it.
struct CircleIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Palette.pillFill, in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - First-run guide
//
// Ported from AutoCodeBar's `Components.swift`, which is the reference standard
// for Dukou's windows. Only the tokens differ: the aurora is tinted with the
// logo green rather than the reference's teal.

/// Where the guide is up to: the step names laid out flat, the current one in
/// ink with a rule under it.
///
/// A bar rather than dots: the four steps have names, and a name is what tells
/// someone whether the step they are dreading is still ahead of them.
struct StepBar: View {
    let steps: [String]
    let current: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                VStack(spacing: 9) {
                    Text(step)
                        .font(.system(size: 13, weight: index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? Theme.ink : Theme.inkTertiary)
                    Rectangle()
                        .fill(index == current ? Theme.ink : Color.clear)
                        .frame(height: 2)
                }
                .frame(width: 96)
                .contentShape(Rectangle())

                if index < steps.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.bottom, 11)
                        .padding(.horizontal, 4)
                }
            }
        }
        .animation(Motion.reduced(.easeOut(duration: 0.2)), value: current)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("第 %d 步，共 %d 步", current + 1, steps.count))
    }
}

/// One thing the setup needs, with a tick that fills itself in when the thing is
/// actually true.
///
/// Distinct from `PermissionRow`, which reports a state in a settings pane. This
/// one is a task list: it says "still to do", and it carries the button that
/// does it.
struct ChecklistRow<Trailing: View>: View {
    let done: Bool
    let title: String
    var detail: String?
    var busy = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            ZStack {
                Circle()
                    .fill(done ? Theme.fill : Theme.surface)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle().strokeBorder(done ? Color.clear : Theme.strokeStrong, lineWidth: Stroke.hairline)
                    )
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Theme.onFill)
                }
            }
            .accessibilityLabel(done ? L10n.text("已完成") : L10n.text("未完成"))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typo.rowTitle)
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(Typo.paneCaption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Space.s)
            trailing()
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, 14)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

extension ChecklistRow where Trailing == EmptyView {
    init(done: Bool, title: String, detail: String? = nil, busy: Bool = false) {
        self.init(done: done, title: title, detail: detail, busy: busy, trailing: { EmptyView() })
    }
}

/// The soft ground behind the guide's art column — atmosphere without an
/// illustration to commission, and the only place in Dukou where the brand green
/// is allowed to be a surface rather than a mark.
struct AuroraBackdrop: View {
    var body: some View {
        // The reference's own two-stop ground, kept as it is. §11.2 asks for the
        // two soft glows to become the brand green, not the ground: carrying
        // `accentSoft` into the gradient too made the top of the column a solid
        // green board — measured (22,66,53) in dark against the reference's
        // (15,35,32) — while the bottom landed on `Theme.sunken`, two or three
        // values off the content pane beside it. Loud at the top, gone at the
        // bottom, in one column.
        LinearGradient(
            colors: [
                Color.dynamic(light: 0xDCEFEC, dark: 0x0F2320),
                Color.dynamic(light: 0xF2F6F5, dark: 0x0F1116)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        // Overlays rather than a `ZStack`: a stack takes the size of its largest
        // child, so the 380 pt glow made the backdrop 380 pt wide inside a
        // 300 pt column and painted 40 pt of green over the step's left margin.
        // An overlay is measured by what it sits on, so the gradient — which
        // fills whatever it is given — is what decides the size.
        .overlay {
            Circle()
                .fill(Theme.accent.opacity(0.18))
                .frame(width: 380, height: 380)
                .blur(radius: 90)
                .offset(x: -50, y: -150)
        }
        .overlay {
            Circle()
                .fill(Theme.accentSoft.opacity(0.7))
                .frame(width: 320, height: 320)
                .blur(radius: 100)
                .offset(x: 80, y: 190)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
