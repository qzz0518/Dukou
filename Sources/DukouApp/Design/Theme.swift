import AppKit
import SwiftUI

extension Color {
    /// A dynamic colour is one `NSColor` with two appearance branches. SwiftUI
    /// has no `Color(light:dark:)`, and a SwiftPM executable has no asset
    /// catalogue, so this is the only way to get real light/dark tokens here.
    /// Resolving inside the `NSColor` also means an appearance switch redraws
    /// without any view having to be invalidated.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        dynamic(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1)
    }

    /// The alpha-carrying form. Light strokes are alpha so they recede; dark
    /// strokes are solid, because an alpha line glows against a dark ground.
    static func dynamic(light: UInt32, lightAlpha: Double, dark: UInt32, darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

/// The floating surfaces — shelf, toast, permission card — borrow the system's
/// own materials instead of inventing a palette, because they sit over other
/// people's windows. Only what a material cannot provide is defined here:
/// hairlines, row states, and the colours that have to stay legible on both
/// grounds.
enum Palette {
    static let hairline    = Color.dynamic(light: 0x000000, lightAlpha: 0.10, dark: 0xFFFFFF, darkAlpha: 0.12)
    static let rowHover    = Color.dynamic(light: 0x000000, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.07)
    /// The lit row: the shelf's expanded list and the target picker. The
    /// brand green, not the system blue this used to be — the selection was
    /// the last place on a floating surface where Dukou spoke somebody else's
    /// colour, and a blue wash under a green-badged shelf read as a control
    /// borrowed from another app. Written as hexes rather than
    /// `Theme.accent.opacity(_:)` because the two appearances need different
    /// alphas: a wash that reads on white is invisible on a dark material.
    static let rowSelected = Color.dynamic(light: 0x21A075, lightAlpha: 0.18, dark: 0x3DC08F, darkAlpha: 0.30)
    /// The chip behind the shelf's filename and its round buttons: dark enough
    /// to hold 11 pt text over a file icon of any colour.
    static let pillFill    = Color.dynamic(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.10)

    /// `.red` measures 3.1:1 on a dark material and fails at 11 pt. These are
    /// picked per appearance to clear 4.5:1 on both. There is no green here:
    /// the floating surfaces only ever report failures now, so a success colour
    /// would be a token nothing is allowed to use.
    static let danger      = Color.dynamic(light: 0xC42A32, dark: 0xFF6B70)
    static let warning     = Color.dynamic(light: 0x9A5A08, dark: 0xF5A524)
}

/// The opaque surfaces: the settings window, which is Dukou's only real window
/// and therefore the only place that paints its own light instead of borrowing
/// the desktop's.
///
/// Every colour here is one declaration with two branches, so a pane never has
/// to read `@Environment(\.colorScheme)` to look right in the dark.
enum Theme {

    // MARK: - Surfaces

    /// Cards, wells and the navigation column: one step quieter than `raised`.
    static let sunken = Color.dynamic(light: 0xF6F6F8, dark: 0x1C1C1F)
    /// Rows and navigation items under the pointer.
    static let hover = Color.dynamic(light: 0xEDEDF0, dark: 0x232327)
    /// The selected navigation item.
    static let selected = Color.dynamic(light: 0xE4E4E8, dark: 0x2B2B30)
    /// The content column — the plane the panes are drawn on.
    static let raised = Color.dynamic(light: 0xFFFFFF, dark: 0x1E1E22)
    /// Controls that sit on `sunken` and still have to read as inset.
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x151517)
    /// Segmented choices need a distinct selected surface inside their well.
    static let choiceSelected = Color.dynamic(light: 0xFFFFFF, dark: 0x3A3A42)
    static let choiceDivider = Color.dynamic(light: 0xCACAD2, dark: 0x55555F)

    // MARK: - Lines

    static let stroke = Color.dynamic(light: 0xE6E6EA, dark: 0x2E2E34)
    static let strokeStrong = Color.dynamic(light: 0xD5D5DB, dark: 0x3C3C43)
    /// Editable fields need a readable boundary against their fill (over 3:1).
    static let inputStroke = Color.dynamic(light: 0x85858F, dark: 0x70707A)

    // MARK: - Ink

    static let ink = Color.dynamic(light: 0x0B0B0D, dark: 0xF4F4F6)
    static let inkSecondary = Color.dynamic(light: 0x6C6C76, dark: 0x9F9FA8)
    static let inkTertiary = Color.dynamic(light: 0xADADB4, dark: 0x6C6C74)
    /// High-contrast pill: black on light, white on dark.
    static let fill = Color.dynamic(light: 0x121214, dark: 0xF4F4F6)
    /// Text on `fill`.
    static let onFill = Color.dynamic(light: 0xFFFFFF, dark: 0x0B0B0D)
    /// The lit side of a switch and the filled checkbox: the brand green. An
    /// earlier build painted these in ink — a white track with a black knob in
    /// dark mode — which the user rejected on sight (2026-09-06).
    static let controlOn = accent

    // MARK: - Semantic

    /// The green of the app icon's bubble (`Resources/AppIcon-artwork.png`).
    /// Identity, the row highlight that follows it (`Palette.rowSelected`),
    /// and through `controlOn` the on-state of every switch and checkbox.
    static let accent = Color.dynamic(light: 0x21A075, dark: 0x3DC08F)
    static let accentSoft = Color.dynamic(light: 0xE4F5EE, dark: 0x12332A)
    static let positive = Color.dynamic(light: 0x1B9E5B, dark: 0x37C77E)
    static let positiveSoft = Color.dynamic(light: 0xE6F5EC, dark: 0x14301F)
    static let warning = Color.dynamic(light: 0xC77A08, dark: 0xE3A13A)
    static let warningSoft = Color.dynamic(light: 0xFCF2E2, dark: 0x33260F)
    static let danger = Color.dynamic(light: 0xD93A34, dark: 0xF2695F)
    static let dangerSoft = Color.dynamic(light: 0xFCECEB, dark: 0x361817)
}

enum Space {
    static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12
    static let l: CGFloat = 16, xl: CGFloat = 20, xxl: CGFloat = 28
    /// Between two settings sections. Wide enough that the section labels, not
    /// a rule, are what separates them.
    static let section: CGFloat = 24
}

enum Radius {
    /// Notices, fields, navigation items — anything the size of one row.
    static let control: CGFloat = 10
    static let row: CGFloat = 8
    static let card: CGFloat = 12
    /// A floating panel that holds a list rather than a sentence: the target
    /// picker. One step rounder than the toast, one step less than the shelf.
    static let panel: CGFloat = 14
    static let shelf: CGFloat = 18
}

enum Stroke {
    static let hairline: CGFloat = 1, focus: CGFloat = 2
}

// MARK: - Type
//
// Two faces, split by script, never mixed inside one Text. `.rounded` is a no-op
// on Chinese glyphs — CJK falls back to the PingFang UI cut with identical
// metrics — so a rounded font on a mixed string silently splits its personality.

extension Font {
    /// Numerals, byte counts and clock times. Tabular figures keep a row from
    /// reflowing as the value changes.
    static func numeral(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Chinese and Latin UI text. Chinese weight mapping breaks above
    /// `.semibold`, so nothing here goes heavier except the one page title,
    /// which is Latin-led and large enough to carry it.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Declared as its own namespace rather than as `Font` statics: `title`, `body`
/// and `caption` already exist on `Font`, and redeclaring them does not compile.
///
/// Two scales, because the surfaces are two sizes. The shelf holds 11 pt text on
/// a 180 pt square over someone else's window; the settings window has 780 pt to
/// itself and reads at the distance a document does.
enum Typo {
    static let title = Font.ui(20, .semibold)
    static let heading = Font.ui(13, .semibold)
    static let body = Font.ui(12)
    static let label = Font.ui(12, .medium)
    static let caption = Font.ui(11)
    static let captionStrong = Font.ui(11, .medium)
    static let micro = Font.ui(10.5)

    /// The settings window.
    static let pageTitle = Font.ui(26, .bold)
    static let paneTitle = Font.ui(21, .semibold)
    static let sectionLabel = Font.ui(12.5, .semibold)
    static let rowTitle = Font.ui(15, .semibold)
    static let paneBody = Font.ui(13.5)
    static let paneBodyStrong = Font.ui(13.5, .medium)
    static let paneCaption = Font.ui(12)
}

enum Metrics {
    /// The collapsed shelf: one square, big enough for a 96 pt icon and a name,
    /// small enough to sit over someone else's window without taking it over.
    static let shelfBlobSide: CGFloat = 180
    static let shelfIconSide: CGFloat = 88
    static let shelfListWidth: CGFloat = 300
    static let shelfRowHeight: CGFloat = 50
    /// Named because the drag has to lift the icon out of exactly the square the
    /// row drew it in.
    static let shelfRowIconSide: CGFloat = 26
    /// Tall enough to leave clear card above the ✕ / ⌄ row for the drag handle
    /// to live in: at 38 the 22 pt circles reached into the handle's own band.
    static let shelfHeaderHeight: CGFloat = 44
    static let shelfVisibleRows = 5
    /// Transparent ring around the shelf card inside its panel. The bump grows
    /// the card by 5 %, and a window clips whatever leaves its frame — without
    /// this the rounded corners and the hairline are sheared off at the peak of
    /// the animation. 8 pt covers 5 % of the tallest state (a five-row list).
    static let shelfBumpInset: CGFloat = 8
    /// The drag handle Dropover puts on its blob: the one affordance that says
    /// the window itself can be moved.
    static let shelfGripSize = CGSize(width: 36, height: 4)

    /// Distance from the screen's `visibleFrame` to the shelf and the toast.
    /// The shelf docks to whichever of the four corners the user picked and the
    /// toast keeps to the top-right, but an inset that differed between them
    /// would read as one of the two being misaligned.
    static let screenMargin: CGFloat = 12

    /// Wide enough for a sentence about a failure, narrow enough that it never
    /// reads as a dialog.
    static let toastMaxWidth: CGFloat = 360
    static let toastMinHeight: CGFloat = 36
    /// Gap between the toast and the shelf it has stepped aside for.
    static let toastGap: CGFloat = 10
    /// How far above its resting place a toast starts.
    static let toastDrop: CGFloat = 6

    /// The settings window. Fixed, because every pane is written to this width
    /// and a resizable one would only ever be resized wrong.
    static let settingsWidth: CGFloat = 780
    static let settingsHeight: CGFloat = 560
    static let settingsNavWidth: CGFloat = 200
    /// The navigation column runs to the top of the window and the traffic
    /// lights are drawn over it, so the first item starts below them.
    static let settingsTrafficLightInset: CGFloat = 38

    /// The first-run guide. Larger than the settings window because it is read
    /// once, at full attention, and every step has to fit without scrolling —
    /// a guide the user has to scroll is a guide whose next button they cannot
    /// see.
    static let onboardingWidth: CGFloat = 920
    static let onboardingHeight: CGFloat = 600
    /// The art column on the left. The card inside it stops short of the edges
    /// so the aurora reads as a ground rather than as a border.
    static let onboardingArtWidth: CGFloat = 300
    static let onboardingArtContentWidth: CGFloat = 252
}

/// One curve for state, one set of durations for windows appearing.
///
/// Nothing here ever travels: a panel appears where it belongs and fades in on
/// the spot. A window that flies across the screen from the pointer to its
/// resting place is 300 ms of the user's attention spent on a journey that tells
/// them nothing, over an app they were in the middle of using.
enum Motion {
    static let ui = Animation.easeOut(duration: 0.16)

    /// A floating panel arriving: alpha with a 0.96 → 1 settle of its content.
    static let panelIn: TimeInterval = 0.18
    /// Leaving is faster than arriving — nobody watches a window go.
    static let panelOut: TimeInterval = 0.12
    /// One nudge when something joins a shelf that is already on screen.
    static let bump: TimeInterval = 0.22
    static let toastIn: TimeInterval = 0.16
    static let toastOut: TimeInterval = 0.20
    /// Holding station with a window somebody else is dragging. Short enough
    /// that successive hops read as one continuous follow, and short enough not
    /// to count as an entrance.
    static let follow: TimeInterval = 0.18

    /// For AppKit code, which has no SwiftUI environment to read.
    static var systemReducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Window animations collapse to nothing under reduce motion rather than
    /// shortening: a panel that snaps into place is the honest version of a
    /// panel that fades in, and there is no state left unexplained by it.
    static func duration(_ seconds: TimeInterval) -> TimeInterval {
        systemReducesMotion ? 0 : seconds
    }

    /// Reduced motion never means "no feedback": the change still has to be
    /// legible, it just must not spring.
    static func reduced(_ animation: Animation, _ reduce: Bool = systemReducesMotion) -> Animation {
        reduce ? .easeOut(duration: 0.12) : animation
    }
}
