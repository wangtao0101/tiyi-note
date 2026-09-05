import SwiftUI
import UIKit

enum TiyiNoteTheme {
    static let workspace = adaptive(
        light: rgb(0.969, 0.976, 0.984),
        dark: rgb(0.028, 0.030, 0.034)
    )
    static let chrome = adaptive(
        light: rgb(1.000, 1.000, 1.000),
        dark: rgb(0.045, 0.047, 0.053)
    )
    static let toolbar = adaptive(
        light: rgb(1.000, 1.000, 1.000),
        dark: rgb(0.075, 0.078, 0.087)
    )
    /// The document workspace deliberately keeps one deep-blue chrome in both appearances,
    /// matching the two-level Goodnotes document and tool bars instead of the white library UI.
    static let documentChrome = Color(red: 0.035, green: 0.112, blue: 0.245)
    static let documentToolbar = Color(red: 0.045, green: 0.151, blue: 0.318)
    /// Goodnotes uses a very light neutral desk around white paper. Keeping this distinct from the
    /// sheet makes its restrained left-edge shadow legible without returning to a dark canvas.
    static let documentWorkspace = Color(uiColor: .systemGray6)
    static let documentChromeForeground = Color.white.opacity(0.92)
    static let documentChromeMuted = Color.white.opacity(0.62)
    static let documentToolSelection = Color(red: 0.800, green: 0.906, blue: 0.988)
    static let documentChromeDanger = Color(red: 1.000, green: 0.500, blue: 0.455)
    static let sidebar = adaptive(
        light: rgb(0.949, 0.961, 0.976),
        dark: rgb(0.037, 0.037, 0.041)
    )
    static let surface = adaptive(
        light: rgb(1.000, 1.000, 1.000),
        dark: rgb(0.095, 0.098, 0.108)
    )
    static let surfaceRaised = adaptive(
        light: rgb(0.941, 0.953, 0.969),
        dark: rgb(0.125, 0.129, 0.142)
    )
    static let surfaceSelected = adaptive(
        light: rgb(0.890, 0.925, 0.980),
        dark: rgb(0.158, 0.162, 0.177)
    )

    static let paperWhite = Color(red: 0.945, green: 0.928, blue: 0.892)
    static let textPrimary = adaptive(
        light: UIColor.black,
        dark: rgb(0.955, 0.945, 0.922)
    )
    static let textSecondary = adaptive(
        light: UIColor.black.withAlphaComponent(0.62),
        dark: rgb(0.690, 0.684, 0.663)
    )
    static let textTertiary = adaptive(
        light: UIColor.black.withAlphaComponent(0.42),
        dark: rgb(0.440, 0.440, 0.432)
    )

    // One Goodnotes-style blue language for every selected and active state.
    static let selectionBlue = Color(red: 0.039, green: 0.518, blue: 1.000)
    static let selectionBackground = selectionBlue.opacity(0.15)
    static let selectionBorder = selectionBlue.opacity(0.96)
    static let selectionForeground = selectionBlue
    static let selectionPressed = selectionBlue.opacity(0.24)
    static let activeUnderline = selectionBlue
    static let lassoBlue = selectionBlue
    static let success = Color(red: 0.455, green: 0.745, blue: 0.590)
    static let danger = Color(red: 0.895, green: 0.485, blue: 0.450)

    static let hairline = adaptive(
        light: UIColor.black.withAlphaComponent(0.075),
        dark: UIColor.white.withAlphaComponent(0.095)
    )
    static let strongHairline = adaptive(
        light: UIColor.black.withAlphaComponent(0.125),
        dark: UIColor.white.withAlphaComponent(0.15)
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
