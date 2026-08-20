//
//  FontScale.swift
//  Cling
//

import Defaults
import SwiftUI

// MARK: - FontRole

/// How much of the user's text-size change each part of the window takes.
///
/// One factor applied everywhere would make 150% mean "half as many results on
/// screen": the furniture grows exactly as fast as the file names the user asked
/// to see better, and the window is the same size it always was. So each role
/// takes a share of the change instead, and the results table leads.
enum FontRole {
    /// Result rows, stash rows, history and log entries. What the app exists to show.
    case content
    /// Preview panel and the query field. Read just as often, but both steal room
    /// from the results, so they trail the table.
    case secondary
    /// Action Bar, Open With and Scripts rows. Labels tucked next to icons whose
    /// size is fixed, so a large jump only breaks the alignment.
    case control
    /// Status bar, hints, pin and quit. Ambient text that must not push results down.
    case chrome

    /// Fraction of the scale change this role takes. Content takes all of it.
    var share: CGFloat {
        switch self {
        case .content: 1
        case .secondary: 0.6
        case .control: 0.35
        case .chrome: 0.15
        }
    }
}

// MARK: - FontScale

enum FontScale {
    static let range: ClosedRange<Double> = 0.8 ... 2.0
    static let step = 0.1

    static var current: Double {
        Defaults[.fontScale]
    }

    /// A point size in the user's chosen scale, rounded to whole points so glyphs
    /// stay on the pixel grid.
    static func size(_ base: CGFloat, _ role: FontRole = .content) -> CGFloat {
        (base * factor(role)).rounded()
    }

    /// Row heights, icon boxes and column widths, which have to grow with the text
    /// they sit next to or the cell clips.
    static func length(_ base: CGFloat, _ role: FontRole = .content) -> CGFloat {
        (base * factor(role)).rounded()
    }

    static func adjust(by delta: Double) {
        let stepped = ((current + delta) / step).rounded() * step
        Defaults[.fontScale] = min(max(stepped, range.lowerBound), range.upperBound)
    }

    static func reset() {
        Defaults[.fontScale] = 1
    }

    private static func factor(_ role: FontRole) -> CGFloat {
        1 + (CGFloat(current) - 1) * role.share
    }
}

extension Font {
    /// `.system(size:)` in the user's text size. The role decides how much of the
    /// scale actually reaches this piece of text.
    static func scaled(
        _ size: CGFloat,
        _ role: FontRole = .content,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: FontScale.size(size, role), weight: weight, design: design)
    }
}
