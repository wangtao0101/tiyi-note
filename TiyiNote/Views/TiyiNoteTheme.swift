import SwiftUI

enum TiyiNoteTheme {
    static let workspace = Color(red: 0.028, green: 0.030, blue: 0.034)
    static let chrome = Color(red: 0.045, green: 0.047, blue: 0.053)
    static let toolbar = Color(red: 0.075, green: 0.078, blue: 0.087)
    static let sidebar = Color(red: 0.037, green: 0.037, blue: 0.041)
    static let surface = Color(red: 0.095, green: 0.098, blue: 0.108)
    static let surfaceRaised = Color(red: 0.125, green: 0.129, blue: 0.142)
    static let surfaceSelected = Color(red: 0.158, green: 0.162, blue: 0.177)

    static let paperWhite = Color(red: 0.945, green: 0.928, blue: 0.892)
    static let textPrimary = Color(red: 0.955, green: 0.945, blue: 0.922)
    static let textSecondary = Color(red: 0.690, green: 0.684, blue: 0.663)
    static let textTertiary = Color(red: 0.440, green: 0.440, blue: 0.432)

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

    static let hairline = Color.white.opacity(0.095)
    static let strongHairline = Color.white.opacity(0.15)
}
