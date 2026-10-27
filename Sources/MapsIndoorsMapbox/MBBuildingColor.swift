//
//  MBBuildingColor.swift
//  MapsIndoorsMapbox
//
//  Copyright © 2026 MapsPeople A/S. All rights reserved.
//

import Foundation

/// A `colorBuildings` value split into its colour and its alpha, so the building fade can vary only
/// the alpha and leave a style's own building colour alone (SPEX-2517).
///
/// Parses the style-spec colour forms the style can report: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`,
/// `rgb()`/`rgba()`, `hsl()`/`hsla()`, and the equivalent `["rgba", …]`/`["hsla", …]` expressions.
/// Written back in the model it was read in, so hue, saturation and lightness round-trip unchanged.
struct MBBuildingColor: Equatable {
    enum Model: Equatable { case rgb, hsl }

    let model: Model
    /// Red, green, blue (0–255) for `.rgb`; hue (0–360), saturation and lightness (0–100) for `.hsl`.
    let c0: Double
    let c1: Double
    let c2: Double
    /// 0–1.
    let alpha: Double

    /// Standard's documented default, `hsl(40, 43%, 93%)`.
    static let standardDefault = MBBuildingColor(model: .hsl, c0: 40, c1: 43, c2: 93, alpha: 1)

    /// Channels are brought into range as CSS does: RGB clamped to 0–255, hue wrapped to 0–360,
    /// saturation and lightness clamped to 0–100. A host style's value is not under SDK control.
    init(model: Model, c0: Double, c1: Double, c2: Double, alpha: Double) {
        self.model = model
        switch model {
        case .rgb:
            self.c0 = Self.clamp(c0, to: 255)
            self.c1 = Self.clamp(c1, to: 255)
            self.c2 = Self.clamp(c2, to: 255)
        case .hsl:
            let hue = c0.truncatingRemainder(dividingBy: 360)
            self.c0 = hue < 0 ? hue + 360 : hue
            self.c1 = Self.clamp(c1, to: 100)
            self.c2 = Self.clamp(c2, to: 100)
        }
        self.alpha = Self.clamp(alpha)
    }

    func withAlpha(_ alpha: Double) -> MBBuildingColor {
        MBBuildingColor(model: model, c0: c0, c1: c1, c2: c2, alpha: alpha)
    }

    /// Equal within the precision `styleString` writes, so a written value read back matches.
    func isApproximatelyEqual(to other: MBBuildingColor) -> Bool {
        model == other.model
            && [(c0, other.c0), (c1, other.c1), (c2, other.c2), (alpha, other.alpha)].allSatisfy { abs($0 - $1) < 0.01 }
    }

    /// The colour at `alpha` (clamped to 0–1), in style-spec syntax. HSL keeps its `%` units: the
    /// style parser reads unitless saturation and lightness as 0–1 fractions, which turns most
    /// colours white.
    func styleString(alpha: Double) -> String {
        let a = Self.format(Self.clamp(alpha))
        switch model {
        case .rgb: return "rgba(\(Self.format(c0)), \(Self.format(c1)), \(Self.format(c2)), \(a))"
        case .hsl: return "hsla(\(Self.format(c0)), \(Self.format(c1))%, \(Self.format(c2))%, \(a))"
        }
    }

    /// Parses a value read from the style (a colour string or a colour expression array), or `nil`
    /// for anything else.
    init?(styleValue: Any) {
        if let string = styleValue as? String {
            self.init(colorString: string)
        } else if let array = styleValue as? [Any] {
            self.init(expression: array)
        } else {
            return nil
        }
    }

    // MARK: - Parsing

    private init?(colorString: String) {
        let s = colorString.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            self.init(hex: String(s.dropFirst()))
            return
        }
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let function = String(s[..<open])
        let arguments = s[s.index(after: open)..<s.index(before: s.endIndex)]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map(String.init)
        self.init(function: function, arguments: arguments.map { (value: Double($0.replacingOccurrences(of: "%", with: "")), percent: $0.hasSuffix("%")) })
    }

    private init?(expression: [Any]) {
        guard let function = expression.first as? String else { return nil }
        let arguments = expression.dropFirst().map { (value: ($0 as? NSNumber)?.doubleValue, percent: false) }
        self.init(function: function, arguments: Array(arguments), expression: true)
    }

    /// `expression`: expression arguments are bare numbers on the CSS scales (S/L 0–100), whereas a
    /// unitless S/L in a colour *string* is a 0–1 fraction.
    private init?(function: String, arguments: [(value: Double?, percent: Bool)], expression: Bool = false) {
        let model: Model
        switch function {
        case "rgb", "rgba": model = .rgb
        case "hsl", "hsla": model = .hsl
        default: return nil
        }
        guard arguments.count == 3 || arguments.count == 4 else { return nil }
        let values = arguments.compactMap(\.value)
        guard values.count == arguments.count, values.allSatisfy(\.isFinite) else { return nil }

        func channel(_ i: Int) -> Double {
            let (v, percent) = (values[i], arguments[i].percent)
            switch model {
            case .rgb: return percent ? v * 2.55 : v
            case .hsl where i == 0: return v
            case .hsl: return percent || expression ? v : v * 100
            }
        }
        var alpha = 1.0
        if values.count == 4 {
            alpha = arguments[3].percent ? values[3] / 100 : values[3]
        }
        self.init(model: model, c0: channel(0), c1: channel(1), c2: channel(2), alpha: alpha)
    }

    private init?(hex: String) {
        let digits: [Character]
        switch hex.count {
        case 3, 4: digits = hex.flatMap { [$0, $0] }
        case 6, 8: digits = Array(hex)
        default: return nil
        }
        var bytes: [Double] = []
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[i...i + 1]), radix: 16) else { return nil }
            bytes.append(Double(byte))
        }
        self.init(model: .rgb, c0: bytes[0], c1: bytes[1], c2: bytes[2], alpha: bytes.count == 4 ? bytes[3] / 255 : 1)
    }

    // MARK: - Helpers

    private static func clamp(_ value: Double, to upper: Double = 1) -> Double { min(max(value, 0), upper) }

    /// Shortest decimal form, e.g. `40`, `0.5`, `93.25`.
    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() && abs(rounded) < 1e15 ? String(Int(rounded)) : String(rounded)
    }
}
