//
//  Typography.swift
//  SensingApp
//
//  One place for the app's text styles.
//
//  WHY THIS EXISTS: every font in the app used to be `.system(size: N, design:
//  .rounded)`, which is a FIXED point size — it ignores the system "Larger
//  Text" setting entirely. Our participants are older post-surgery patients,
//  a group that runs Dynamic Type well above the default more often than
//  almost any other, so the app was unreadable for them no matter what they
//  set in Settings.
//
//  The fix is to express every font as a semantic TEXT STYLE (.body,
//  .footnote, …) instead of a number. iOS then scales it. At the default
//  "Large" setting the styles below render at the same point sizes the app
//  was hardcoding, so nothing moves for a patient who hasn't changed the
//  setting:
//
//      .caption2   11      .subheadline  15      .title2     22
//      .caption    12      .callout      16      .title      28
//      .footnote   13      .body         17      .largeTitle 34
//                          .title3       20
//
//  DENSE LAYOUTS: a few places genuinely cannot absorb accessibility sizes —
//  the 7-column week strip, the 3-column stat grid, the 0–10 pain scale. Those
//  containers cap growth with `.dynamicTypeSize(...DynamicTypeSize.accessibility1)`
//  so the text still grows a long way but does not shred the grid. Cap the
//  CONTAINER, never the individual Text, or the cap has to be repeated on
//  every label inside it.
//

import SwiftUI

extension Font {

    /// The app's rounded typeface at a Dynamic Type-aware size.
    ///
    /// Use in place of `.system(size:weight:design:)`:
    ///
    ///     .font(.journey(.subheadline, weight: .semibold))
    ///
    /// - Parameters:
    ///   - style: the semantic size. Pick by what the text IS (a caption, a
    ///     title), not by the number it happens to render at today.
    ///   - weight: optional weight, applied on top of the style.
    static func journey(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded).weight(weight)
    }

    /// Monospaced digits at a Dynamic Type-aware size — for the live sensor
    /// readouts, where columns of numbers should not jitter as values change.
    static func journeyMono(_ style: Font.TextStyle) -> Font {
        .system(style, design: .monospaced)
    }
}

extension View {

    /// Ceiling for text growth inside a fixed-geometry container (grids,
    /// strips, calendars). Text still scales through the whole normal range
    /// and one accessibility step beyond it — it just stops before the layout
    /// breaks apart.
    func journeyDenseLayout() -> some View {
        dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}
