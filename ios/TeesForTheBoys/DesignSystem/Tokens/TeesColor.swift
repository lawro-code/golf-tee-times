import SwiftUI
import UIKit

/// The semantic colour layer. This is the only colour API a screen should use.
///
/// **Why there is no theme object and no `ColorScheme` parameter.** Every
/// static below is a `Color` backed by a `UIColor` dynamic provider: UIKit
/// asks the provider for a value each time it resolves against a trait
/// collection, so `TeesColor.ink` is already the right ink in both schemes, in
/// a preview, in a sheet that renders dark inside a light app, and when the
/// phone flips at sunset. A component writes `.foregroundStyle(TeesColor.ink)`
/// and is finished. An environment object would push that decision onto every
/// caller and be forgotten in exactly one view.
///
/// **Why the dark scheme is not an inversion.** Inverting Augusta cream gives
/// you a grey-brown page that looks like a bug. The dark scheme here is a
/// second, deliberate design — a Masters scoreboard at dusk: a near-black
/// green ground, cream numerals, gold rules. Cream is never the ground.
///
/// **Why `resolved(_:_:)` exists.** `SwiftUI.Color` is opaque — you cannot
/// read components back out of one, so nothing about it can be asserted. The
/// resolver is the single source of truth that both the statics and the
/// contrast tests read, which is why every static below is literally
/// `color(.thatRole)` and never a hand-written `Color`. Add a role without
/// giving it a value and the switch stops compiling.
public enum TeesColor {

    // MARK: - Ground

    /// The page. Cream in light, near-black scoreboard green in dark.
    public static let background = color(.background)
    /// A recessed band inside the page — section backing, grouped rows.
    public static let backgroundSoft = color(.backgroundSoft)
    /// A raised card on the page. The `.slot` tile's fill.
    public static let surface = color(.surface)
    /// A deliberately inverted panel: the masthead, a green banner. Dark in
    /// both schemes, which is why `onInverse` exists.
    public static let surfaceInverse = color(.surfaceInverse)

    // MARK: - Ink

    /// Primary text.
    public static let ink = color(.ink)
    /// Secondary text — still a reading weight, not a whisper.
    public static let inkSoft = color(.inkSoft)
    /// Labels, captions, metadata. Clears 4.5:1 on `background` in both
    /// schemes; it is small text, so it has to.
    public static let muted = color(.muted)
    /// Text on `surfaceInverse`.
    public static let onInverse = color(.onInverse)
    /// Secondary text on `surfaceInverse` — the tagline under the masthead.
    public static let onInverseSoft = color(.onInverseSoft)

    // MARK: - Line

    /// A one-point rule or card border.
    public static let hairline = color(.hairline)
    /// A rule meant to be seen — the gold-dotted divider under the masthead.
    public static let hairlineStrong = color(.hairlineStrong)

    // MARK: - Brand

    /// The brand marks keep their literal ramp value in both schemes. A crest
    /// that changes colour at dusk is not a crest.
    public static let green = color(.green)
    public static let greenDeep = color(.greenDeep)
    public static let greenBoard = color(.greenBoard)
    public static let gold = color(.gold)
    public static let goldBright = color(.goldBright)
    public static let goldSoft = color(.goldSoft)

    // MARK: - Status

    /// A green fee. `.slot-price`.
    public static let price = color(.price)
    /// A twilight rate. `.slot-price.twilight`.
    public static let priceTwilight = color(.priceTwilight)
    /// Something wrong: a failed scrape, a stale-data banner.
    public static let alert = color(.alert)
    /// The interactive accent — links, selected chips, the active filter.
    public static let accent = color(.accent)
    /// The 3px left border on a `.slot` tile.
    public static let leadingRule = color(.leadingRule)
}

// MARK: - Scheme

/// Which of the two designs to resolve. Mirrors `ColorScheme`, but is its own
/// type so the resolver and its tests do not depend on SwiftUI's environment.
public enum TeesScheme: Sendable {
    case light
    case dark
}

// MARK: - Roles

/// One case per static on `TeesColor`. `CaseIterable` so a test can walk every
/// role and prove the dark scheme was finished rather than half-written.
public enum TeesColorRole: String, CaseIterable, Sendable {
    case background
    case backgroundSoft
    case surface
    case surfaceInverse

    case ink
    case inkSoft
    case muted
    case onInverse
    case onInverseSoft

    case hairline
    case hairlineStrong

    case green
    case greenDeep
    case greenBoard
    case gold
    case goldBright
    case goldSoft

    case price
    case priceTwilight
    case alert
    case accent
    case leadingRule
}

// MARK: - Resolver

public extension TeesColor {

    /// The literal components of `role` in `scheme`. The single source of
    /// truth for this design system's colour, and the only part of it that can
    /// be asserted on.
    static func resolved(_ role: TeesColorRole, _ scheme: TeesScheme) -> TeesRGBA {
        switch scheme {
        case .light: return light(role)
        case .dark: return dark(role)
        }
    }

    /// A dynamic `Color` for `role`: resolves itself against whatever trait
    /// collection it is drawn into, so callers never branch on scheme.
    static func color(_ role: TeesColorRole) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(teesRGBA: resolved(role, traits.userInterfaceStyle == .dark ? .dark : .light))
        })
    }

    // MARK: Light — a direct port of docs/style.css `:root`

    /// Three roles below are NOT the stylesheet's literal value, and each
    /// deviation is here because the stylesheet's value fails WCAG AA on
    /// Augusta cream. A design token that cannot be read is not a token:
    ///
    /// - `muted`: `--muted` #76735a is 3.86:1 on cream. Darkened along its own
    ///   hue to #67644e (4.81:1). It is caption-sized text, so 4.5:1 applies.
    /// - `priceTwilight`: `--twilight` #b6541c is 3.95:1 on cream. Darkened to
    ///   #a04919 (4.87:1). The dark scheme lifts the same colour the other
    ///   way; the website has the same problem and should follow.
    /// - (`--masters-red` #c8102e is 4.73:1 on cream and is used as-is.)
    ///
    /// Everything else is the literal `:root` value.
    private static func light(_ role: TeesColorRole) -> TeesRGBA {
        switch role {
        case .background: return TeesPalette.cream
        case .backgroundSoft: return TeesPalette.creamSoft
        case .surface: return TeesPalette.surfaceCream
        case .surfaceInverse: return TeesPalette.greenDeep

        case .ink: return TeesPalette.ink
        case .inkSoft: return TeesPalette.inkSoft
        case .muted: return dusk("#67644e")
        case .onInverse: return TeesPalette.onGreen
        case .onInverseSoft: return TeesPalette.onGreen.opacity(0.7)

        case .hairline: return TeesPalette.hairline
        case .hairlineStrong: return TeesPalette.hairlineStrong

        case .green: return TeesPalette.green
        case .greenDeep: return TeesPalette.greenDeep
        case .greenBoard: return TeesPalette.greenBoard
        case .gold: return TeesPalette.gold
        case .goldBright: return TeesPalette.goldBright
        case .goldSoft: return TeesPalette.goldSoft

        case .price: return TeesPalette.green
        case .priceTwilight: return dusk("#a04919")
        case .alert: return TeesPalette.mastersRed
        case .accent: return TeesPalette.green
        case .leadingRule: return TeesPalette.green
        }
    }

    // MARK: Dark — a Masters scoreboard at dusk

    /// Not an inversion. The ground walks *down* from `--green-board` rather
    /// than up from cream, so the page reads as a lit scoreboard in a dark
    /// room. Ink is cream; the rules go gold because a black-green hairline
    /// is invisible on black-green.
    ///
    /// Two of the status colours are lifted, because the ramp value is a
    /// light-scheme colour and does not survive a near-black ground:
    ///
    /// - `priceTwilight`: `--twilight` #b6541c is 3.70:1 here. Lifted to
    ///   #e08a4a (6.85:1).
    /// - `alert`: `--masters-red` #c8102e is 3.09:1 here. Lifted to #ea4a61
    ///   (4.90:1). #e03a52 — the first lift tried — is 4.24:1 and still short
    ///   of AA, which is the kind of near-miss this file's tests exist to
    ///   catch.
    private static func dark(_ role: TeesColorRole) -> TeesRGBA {
        switch role {
        case .background: return TeesPalette.greenBoard
        case .backgroundSoft: return dusk("#00120a")
        case .surface: return TeesPalette.greenDeep
        case .surfaceInverse: return dusk("#000d07")

        case .ink: return TeesPalette.onGreen
        case .inkSoft: return TeesPalette.cream.opacity(0.82)
        case .muted: return TeesPalette.cream.opacity(0.58)
        case .onInverse: return TeesPalette.cream
        case .onInverseSoft: return TeesPalette.cream.opacity(0.7)

        case .hairline: return TeesPalette.goldBright.opacity(0.16)
        case .hairlineStrong: return TeesPalette.goldBright.opacity(0.34)

        case .green: return TeesPalette.green
        case .greenDeep: return TeesPalette.greenDeep
        case .greenBoard: return TeesPalette.greenBoard
        case .gold: return TeesPalette.gold
        case .goldBright: return TeesPalette.goldBright
        case .goldSoft: return TeesPalette.goldSoft

        case .price: return dusk("#f9f3dc")
        case .priceTwilight: return dusk("#e08a4a")
        case .alert: return dusk("#ea4a61")
        case .accent: return TeesPalette.goldBright
        case .leadingRule: return TeesPalette.gold
        }
    }
}

// MARK: - Non-ramp literals

/// Trapping hex parse for the scheme literals below — the dark ground, and the
/// lifted status colours. Same reasoning as `TeesPalette.rgb`: these are
/// compile-time constants, so a bad one is a typo in this file and should stop
/// the first test that touches it, not silently fall back to a wrong colour.
private func dusk(_ hex: String) -> TeesRGBA {
    guard let colour = TeesRGBA(hex: hex) else {
        preconditionFailure("TeesColor: not a hex colour: \(hex)")
    }
    return colour
}

// MARK: - UIKit bridge

private extension UIColor {
    /// `UIColor.init(red:green:blue:alpha:)` keeps the components verbatim, so
    /// what a view draws is what `TeesColor.resolved` returned and what the
    /// contrast tests asserted on.
    convenience init(teesRGBA colour: TeesRGBA) {
        self.init(
            red: CGFloat(colour.r),
            green: CGFloat(colour.g),
            blue: CGFloat(colour.b),
            alpha: CGFloat(colour.a))
    }
}
