//
//  FilterAppearance.swift
//  Cling
//
//  The icon and colour a filter carries, so the search window can say what it is scoped to
//  without spending a word on it.
//

import Defaults
import SwiftUI
import SymbolPicker

// MARK: - FilterColor

/// A filter's colour, stored as a hue and rendered differently per appearance.
///
/// One colour cannot serve both modes: a colour deep enough to read against a white window turns to
/// mud on a dark one, and a colour bright enough for dark washes out on light. So a filter stores
/// only the hue, and the light and dark renderings are derived from it (see `accent`).
struct FilterColor: Codable, Hashable, Identifiable, Defaults.Serializable {
    init(hue: Double) {
        self.hue = ((hue.isFinite ? hue : 0).truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        try self.init(hue: c.decode(Double.self))
    }

    /// Hues handed out to filters that have never been given one. The slider is continuous, so this
    /// is only the set auto-assignment draws from, spaced far enough apart that two filters rarely
    /// come out looking alike.
    static let palette: [FilterColor] = (0 ..< 30).map { FilterColor(hue: Double($0) / 30) }

    let hue: Double

    var id: Double {
        hue
    }

    /// How much of `tint` to lay over the window.
    static func tintOpacity(dark: Bool) -> Double {
        dark ? 0.22 : 0.20
    }

    /// OKLCH to sRGB, reducing chroma until the colour fits the display gamut.
    ///
    /// Plenty of (L, C) pairs have no sRGB answer at some hues: a vivid green at L 0.55 exists,
    /// the same chroma in blue does not. Clamping the channels instead would shift the hue and
    /// flatten exactly the colours that were most saturated, so back the chroma off instead and
    /// keep the hue the caller asked for.
    static func oklch(l: Double, c: Double, hue: Double) -> Color {
        var chroma = c
        for _ in 0 ..< 12 {
            let (r, g, b) = oklabToLinearSRGB(l: l, chroma: chroma, hue: hue)
            if r >= -0.001, r <= 1.001, g >= -0.001, g <= 1.001, b >= -0.001, b <= 1.001 {
                return Color(
                    red: gamma(r), green: gamma(g), blue: gamma(b)
                )
            }
            chroma *= 0.85
        }
        let (r, g, b) = oklabToLinearSRGB(l: l, chroma: 0, hue: hue)
        return Color(red: gamma(r), green: gamma(g), blue: gamma(b))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hue)
    }

    /// The icon's colour: dark enough to hold against white, light enough to read on black.
    ///
    /// Picked in OKLCH rather than HSB because HSB lightness is a lie. At a fixed HSB brightness a
    /// yellow is far lighter than a blue, so a palette swept through HSB hues visibly pulses as it
    /// goes round, and half of it fails against one background or the other. OKLCH's L is
    /// perceptual, so one L per appearance holds for every hue.
    func accent(dark: Bool) -> Color {
        dark ? Self.oklch(l: 0.80, c: 0.15, hue: hue) : Self.oklch(l: 0.55, c: 0.16, hue: hue)
    }

    /// The wash over the window: the same hue pulled most of the way to the background so it reads
    /// as a tint on a surface you are still reading text off.
    func tint(dark: Bool) -> Color {
        dark ? Self.oklch(l: 0.45, c: 0.10, hue: hue) : Self.oklch(l: 0.86, c: 0.11, hue: hue)
    }

    private static func oklabToLinearSRGB(l: Double, chroma: Double, hue: Double) -> (Double, Double, Double) {
        let h = hue * 2 * .pi
        let a = chroma * cos(h)
        let bb = chroma * sin(h)

        let l_ = l + 0.3963377774 * a + 0.2158037573 * bb
        let m_ = l - 0.1055613458 * a - 0.0638541728 * bb
        let s_ = l - 0.0894841775 * a - 1.2914855480 * bb
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_

        return (
            4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
            -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
            -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        )
    }

    private static func gamma(_ c: Double) -> Double {
        let v = min(max(c, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

// MARK: - BuiltinFilterAppearance

/// Icon and hue for a filter shipped with the app, keyed by name and split by kind: `Documents`
/// exists as both a folder filter and a quick filter, and they are not the same colour.
///
/// Held apart from the filter definitions so a filter that has been renamed or edited keeps
/// whatever it was given.
enum BuiltinFilterAppearance {
    enum Kind { case folder, quick }

    static func icon(for name: String, kind: Kind) -> String? {
        (kind == .folder ? folder : quick)[name]?.icon
    }

    static func color(for name: String, kind: Kind) -> FilterColor? {
        (kind == .folder ? folder : quick)[name].map { FilterColor(hue: $0.hue) }
    }

    private typealias Look = (icon: String, hue: Double)

    private static let folder: [String: Look] = [
        "Applications": ("app.badge", 0.58),
        "Home": ("house", 0.6656),
        "Documents": ("doc.text", 0.09),
        "iCloud": ("icloud", 0.53),
        "System": ("gearshape.2", 0.72),
    ]

    private static let quick: [String: Look] = [
        "Apps": ("app.badge", 0.9999),
        "Folders": ("folder", 0.4622),
        "Images": ("photo", 0.1379),
        "Videos": ("film", 0.6619),
        "Audio": ("waveform", 0.3966),
        "Documents": ("doc.text", 0.2329),
        "Archives": ("shippingbox", 0.2451),
        "Code": ("chevron.left.forwardslash.chevron.right", 0.45),
        "Config": ("ellipsis.curlybraces", 0.2333),
        "PDFs": ("text.rectangle.page.fill", 0.0698),
        "Xcode Projects": ("hammer.fill", 0.7066),
    ]
}

extension FilterColor {
    /// A swatch for a filter that has never been given one, picked from its name so it stays the
    /// same between launches. `hashValue` is seeded per process and would give a filter a new colour
    /// every time the app started.
    static func forName(_ name: String) -> FilterColor {
        var h: UInt64 = 5381
        for b in name.utf8 {
            h = h &* 33 &+ UInt64(b)
        }
        return palette[Int(h % UInt64(palette.count))]
    }
}

// MARK: - The scope the search is currently in

extension FuzzyClient {
    /// The colours washing the window: one, or two when a quick filter and a folder filter are both
    /// narrowing the search. Nil when nothing is.
    var scopeWash: (top: FilterColor, bottom: FilterColor)? {
        let quick = quickFilter.map { $0.color ?? .forName($0.id) }
        let folder = folderFilter.map { $0.color ?? .forName($0.id) }
        if let quick, let folder {
            return (quick, folder)
        }
        if let single = quick ?? folder ?? volumeFilter.map({ FilterColor.forName($0.string) }) {
            return (single, single)
        }
        return nil
    }

    /// Icon and colour for whatever narrows the current search, or nil when it is searching
    /// everything. A quick filter wins over a folder filter, which wins over a volume, matching the
    /// order the query itself applies them in.
    var scopeAppearance: (icon: String, color: FilterColor)? {
        if let f = quickFilter {
            return (f.icon ?? "line.3.horizontal.decrease.circle.fill", f.color ?? .forName(f.id))
        }
        if let f = folderFilter {
            return (f.icon ?? "folder.fill", f.color ?? .forName(f.id))
        }
        if let v = volumeFilter {
            return ("externaldrive.fill", .forName(v.string))
        }
        return nil
    }
}

extension FilterColor {
    /// The hue between two colours, taken the short way round the wheel.
    ///
    /// Both tints share an L and a C, so walking the hue is the LCH interpolation: every colour
    /// along the way is a real, equally-light colour of the same chroma. Blending the two sRGB
    /// values instead would cut a straight chord across the wheel and pass through grey in the
    /// middle, which is what a plain SwiftUI gradient between two hues does.
    static func mix(_ a: FilterColor, _ b: FilterColor, _ t: Double) -> FilterColor {
        var delta = b.hue - a.hue
        if delta > 0.5 {
            delta -= 1
        } else if delta < -0.5 {
            delta += 1
        }
        return FilterColor(hue: a.hue + delta * t)
    }

    /// Stops for the window wash when two filters are narrowing the search at once, sampled along
    /// the LCH arc rather than left to the gradient to interpolate.
    ///
    /// `top` holds the upper two thirds and `bottom` the lower third, with the changeover eased
    /// across a band rather than drawn as a line: a hard edge across the middle of a search window
    /// reads as a rendering fault.
    static func washStops(top: FilterColor, bottom: FilterColor, dark: Bool) -> [Gradient.Stop] {
        let boundary = 2.0 / 3.0, band = 0.3
        return (0 ... 24).map { i in
            let location = Double(i) / 24
            let raw = (location - (boundary - band / 2)) / band
            let clamped = min(max(raw, 0), 1)
            // Smoothstep, so the blend eases in and out instead of starting and stopping abruptly.
            let t = clamped * clamped * (3 - 2 * clamped)
            return Gradient.Stop(color: mix(top, bottom, t).tint(dark: dark), location: location)
        }
    }
}

// MARK: - Shared chrome

extension View {
    /// The filter's hue behind its symbol, thin enough to read as a tint of the window rather than
    /// a second colour: over a light window it lands darker, over a dark one lighter, and either
    /// way the symbol keeps its contrast against it.
    ///
    /// Shared by the editor's icon button and the search window's scope icon so the two cannot
    /// drift apart.
    /// `glow` rings the disc and lifts it off the bar, for the search window's icon while a filter
    /// is actually on: the colour alone says which scope, the glow says that there is one.
    func filterIconBackground(_ color: FilterColor, dark: Bool, glow: Bool = false) -> some View {
        let accent = color.accent(dark: dark)
        return background(Circle().fill(accent.opacity(dark ? 0.24 : 0.16)))
            .overlay {
                if glow {
                    Circle().strokeBorder(accent.opacity(dark ? 0.85 : 0.7), lineWidth: 1)
                }
            }
            .shadow(color: glow ? accent.opacity(dark ? 0.55 : 0.4) : .clear, radius: glow ? 4 : 0)
    }
}

// MARK: - FilterIconButton

/// Shows the filter's symbol and opens the SF Symbols sheet, which brings its own search and
/// category sidebar.
struct FilterIconButton: View {
    @Binding var icon: String

    /// Read, not bound: the button follows the slider live so the symbol is always shown in the
    /// colour it will actually have.
    var color: FilterColor

    var body: some View {
        Button { picking = true } label: {
            let dark = colorScheme == .dark
            Image(systemName: icon.isEmpty ? "questionmark.square.dashed" : icon)
                .foregroundStyle(color.accent(dark: dark))
                .frame(width: 18, height: 18)
                .padding(5)
                .filterIconBackground(color, dark: dark)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $picking) { SymbolPicker(symbol: $icon) }
    }

    @State private var picking = false
    @Environment(\.colorScheme) private var colorScheme
}

// MARK: - HueSlider

/// A continuous hue ramp with a vertical knob, so a filter's colour is a place on the spectrum
/// rather than one of a fixed set.
///
/// The ramp is drawn in the `tint` colours, not the icon's `accent`: those are the ones that follow
/// the window, pale on light and deep on dark, so the slider reads as part of the surface instead of
/// a row of dark bars sitting on a white sheet. The icon button beside it previews the accent.
///
/// Both are sampled from the real OKLCH ramp rather than interpolated. A SwiftUI gradient between
/// two hues blends through sRGB and cuts a chord across the colour wheel, greying the middle.
struct HueSlider: View {
    @Binding var color: FilterColor

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: Self.ramp(dark: colorScheme == .dark), startPoint: .leading, endPoint: .trailing))
                .overlay(alignment: .leading) {
                    knob
                        .offset(x: min(max(color.hue * w, 0), w) - Self.knobWidth / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { color = FilterColor(hue: min(max($0.location.x / max(w, 1), 0), 0.9999)) }
                )
        }
        .frame(width: 160, height: 18)
    }

    private static let knobWidth: CGFloat = 4

    @Environment(\.colorScheme) private var colorScheme

    private var knob: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.white)
            .frame(width: Self.knobWidth, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(.black.opacity(0.35), lineWidth: 1))
            .shadow(radius: 1)
    }

    /// Enough stops that the ramp reads as continuous while each segment is still short enough for
    /// the straight-line blend between neighbours to be invisible.
    private static func ramp(dark: Bool) -> [Color] {
        (0 ... 60).map { FilterColor(hue: Double($0) / 60).tint(dark: dark) }
    }

}
