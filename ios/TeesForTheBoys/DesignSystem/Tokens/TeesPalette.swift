import Foundation

/// The raw colour ramp, transcribed from `docs/style.css` `:root`.
///
/// This is the *ramp*, not the design. Nothing outside `TeesColor` should
/// reach for these directly: a screen that writes `TeesPalette.cream` has
/// pinned itself to the light scheme and will glow white on a scoreboard at
/// dusk. Write `TeesColor.background` instead and let the semantic layer
/// decide. The ramp is public only so the semantic layer, previews and the
/// contrast tests can name the same sixteen values the website names.
///
/// `docs/style.css` is the design source of truth (BUILD-PLAN.md line 24), so
/// every value here is a literal transcription. If the website changes a hex,
/// this file changes with it — and `TeesColorTests` will tell you if the
/// change broke contrast.
public enum TeesPalette {

    // MARK: - Creams

    /// `--bg` — warmer Augusta cream.
    public static let cream = rgb("#f2e6c2")
    /// `--bg-soft`
    public static let creamSoft = rgb("#e5d4a0")
    /// `--surface`
    public static let surfaceCream = rgb("#fbf6e0")

    // MARK: - Inks

    /// `--ink`
    public static let ink = rgb("#14180f")
    /// `--ink-soft`
    public static let inkSoft = rgb("#353a2c")
    /// `--muted`
    public static let muted = rgb("#76735a")

    // MARK: - Greens

    /// `--green` — royal, deeper than Pantone 342.
    public static let green = rgb("#013d22")
    /// `--green-deep`
    public static let greenDeep = rgb("#002616")
    /// `--green-board` — near-black scoreboard green.
    public static let greenBoard = rgb("#001a0e")
    /// `--green-bright`
    public static let greenBright = rgb("#007a48")

    // MARK: - Golds

    /// `--gold`
    public static let gold = rgb("#c9a04e")
    /// `--gold-bright`
    public static let goldBright = rgb("#e6c66f")
    /// `--gold-soft`
    public static let goldSoft = rgb("#efd58a")

    // MARK: - Text on green, and the two status colours

    /// `--on-green` — cream text on green.
    public static let onGreen = rgb("#f4e9c4")
    /// `--masters-red`
    public static let mastersRed = rgb("#c8102e")
    /// `--twilight`
    public static let twilight = rgb("#b6541c")

    // MARK: - Hairlines

    /// `--hairline` — `rgba(0, 28, 18, 0.16)`. A translucent ink-green, not a
    /// grey: it has to sit on cream *and* on a cream surface card without
    /// either edge reading as dirty.
    public static let hairline = TeesRGBA(r: 0, g: 28.0 / 255.0, b: 18.0 / 255.0, a: 0.16)

    /// `--hairline-strong` — `rgba(0, 28, 18, 0.32)`.
    public static let hairlineStrong = TeesRGBA(r: 0, g: 28.0 / 255.0, b: 18.0 / 255.0, a: 0.32)

    // MARK: - The ramp as data

    /// Every opaque ramp colour, paired with the hex `docs/style.css` writes.
    ///
    /// The hex-round-trip test walks this rather than a list of its own, so a
    /// mistyped transcription fails a test instead of shipping a slightly
    /// wrong green. The two hairlines are deliberately absent — they are
    /// `rgba()` in the stylesheet and have no hex form to round-trip.
    public static let ramp: [TeesRampEntry] = [
        TeesRampEntry(name: "cream", hex: "#f2e6c2", color: cream),
        TeesRampEntry(name: "creamSoft", hex: "#e5d4a0", color: creamSoft),
        TeesRampEntry(name: "surfaceCream", hex: "#fbf6e0", color: surfaceCream),
        TeesRampEntry(name: "ink", hex: "#14180f", color: ink),
        TeesRampEntry(name: "inkSoft", hex: "#353a2c", color: inkSoft),
        TeesRampEntry(name: "muted", hex: "#76735a", color: muted),
        TeesRampEntry(name: "green", hex: "#013d22", color: green),
        TeesRampEntry(name: "greenDeep", hex: "#002616", color: greenDeep),
        TeesRampEntry(name: "greenBoard", hex: "#001a0e", color: greenBoard),
        TeesRampEntry(name: "greenBright", hex: "#007a48", color: greenBright),
        TeesRampEntry(name: "gold", hex: "#c9a04e", color: gold),
        TeesRampEntry(name: "goldBright", hex: "#e6c66f", color: goldBright),
        TeesRampEntry(name: "goldSoft", hex: "#efd58a", color: goldSoft),
        TeesRampEntry(name: "onGreen", hex: "#f4e9c4", color: onGreen),
        TeesRampEntry(name: "mastersRed", hex: "#c8102e", color: mastersRed),
        TeesRampEntry(name: "twilight", hex: "#b6541c", color: twilight)
    ]

    /// Trapping hex parse, for compile-time-known literals only. A bad literal
    /// here is a typo in this file, caught the first time anything touches the
    /// palette — including at test time, which is where we want it.
    private static func rgb(_ hex: String) -> TeesRGBA {
        guard let colour = TeesRGBA(hex: hex) else {
            preconditionFailure("TeesPalette: not a hex colour: \(hex)")
        }
        return colour
    }
}

// MARK: - Ramp entry

/// One row of the ramp: the name the stylesheet uses, its hex, and the parsed
/// colour. Exists so `TeesPalette.ramp` can be an array of something `Sendable`
/// rather than a tuple.
public struct TeesRampEntry: Equatable, Sendable {
    public let name: String
    public let hex: String
    public let color: TeesRGBA

    public init(name: String, hex: String, color: TeesRGBA) {
        self.name = name
        self.hex = hex
        self.color = color
    }
}

// MARK: - TeesRGBA

/// A colour as four `0...1` components, plus the WCAG 2.1 arithmetic.
///
/// Deliberately not `SwiftUI.Color`: `Color` is an opaque render-time value
/// you cannot read components back out of, so it cannot be asserted on. Every
/// contrast guarantee this design system makes is made on `TeesRGBA`, and
/// `TeesColor` is the thin layer that turns one into a `Color` for a view.
///
/// Components are sRGB, not linear — `relativeLuminance` does the linearising.
public struct TeesRGBA: Equatable, Sendable {

    /// Red, `0...1`, sRGB (gamma-encoded).
    public let r: Double
    /// Green, `0...1`, sRGB.
    public let g: Double
    /// Blue, `0...1`, sRGB.
    public let b: Double
    /// Alpha, `0...1`. `1` is opaque.
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = TeesRGBA.clamp(r)
        self.g = TeesRGBA.clamp(g)
        self.b = TeesRGBA.clamp(b)
        self.a = TeesRGBA.clamp(a)
    }

    /// Parses `#rgb`, `#rrggbb` or `#rrggbbaa`, with or without the `#`, in
    /// either case. Returns `nil` rather than trapping so the initialiser is
    /// safe to point at a string that came from outside this file.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }

        let bytes: [Double]
        switch digits.count {
        case 3:
            // #rgb expands each digit, so #abc is #aabbcc.
            bytes = digits.compactMap { Int(String($0), radix: 16) }
                .map { Double($0 * 17) / 255.0 }
        case 6, 8:
            var values: [Double] = []
            var index = digits.startIndex
            while index < digits.endIndex {
                let next = digits.index(index, offsetBy: 2)
                guard let byte = Int(digits[index..<next], radix: 16) else { return nil }
                values.append(Double(byte) / 255.0)
                index = next
            }
            bytes = values
        default:
            return nil
        }

        guard bytes.count == 3 || bytes.count == 4 else { return nil }
        self.init(r: bytes[0], g: bytes[1], b: bytes[2], a: bytes.count == 4 ? bytes[3] : 1)
    }

    /// The hex the stylesheet would write: `#rrggbb`, or `#rrggbbaa` when this
    /// colour is translucent. Exactly round-trips `init(hex:)` for any colour
    /// that came from one, because both sides quantise on `/255`.
    public var hexString: String {
        let byte = { (component: Double) -> Int in Int((component * 255).rounded()) }
        let base = String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
        return a >= 1 ? base : base + String(format: "%02x", byte(a))
    }

    // MARK: - WCAG 2.1

    /// Relative luminance, WCAG 2.1 §"relative luminance".
    ///
    /// Alpha is ignored: luminance is only defined for an opaque colour.
    /// Composite first with `composited(over:)` if you need the luminance of
    /// something translucent as it actually renders.
    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// This colour over `backdrop`, source-over, in sRGB space.
    ///
    /// sRGB rather than linear light because that is what Core Animation and
    /// the browser both do — the point is to predict what will actually be on
    /// the glass, not what would be physically correct.
    public func composited(over backdrop: TeesRGBA) -> TeesRGBA {
        guard a < 1 else { return self }
        let outAlpha = a + backdrop.a * (1 - a)
        guard outAlpha > 0 else { return TeesRGBA(r: 0, g: 0, b: 0, a: 0) }
        func mix(_ top: Double, _ bottom: Double) -> Double {
            (top * a + bottom * backdrop.a * (1 - a)) / outAlpha
        }
        return TeesRGBA(
            r: mix(r, backdrop.r),
            g: mix(g, backdrop.g),
            b: mix(b, backdrop.b),
            a: outAlpha)
    }

    /// WCAG 2.1 contrast ratio, `1...21`.
    ///
    /// A translucent receiver is composited over `backdrop` first, so asking
    /// "does `muted` read on `background`" gives the answer for the pixels a
    /// golfer will actually see rather than for a colour that is never drawn
    /// on its own. `backdrop` is expected to be opaque — it is a ground.
    public func contrastRatio(against backdrop: TeesRGBA) -> Double {
        let foreground = composited(over: backdrop).relativeLuminance
        let background = backdrop.relativeLuminance
        let lighter = max(foreground, background)
        let darker = min(foreground, background)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// This colour at a different opacity. The dark scheme is built out of
    /// these: cream at 0.82 is ink-soft, cream at 0.58 is muted.
    public func opacity(_ alpha: Double) -> TeesRGBA {
        TeesRGBA(r: r, g: g, b: b, a: alpha)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
