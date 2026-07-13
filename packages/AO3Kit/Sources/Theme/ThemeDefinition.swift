import SwiftUI

enum BackgroundType: String, Codable, CaseIterable {
    case solid, image, tiledPattern
}

enum CardBorderStyle: String, Codable, CaseIterable {
    case bordered, borderless, shadow
}

struct ThemeDefinition: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var isBuiltIn: Bool

    // Background
    var backgroundType: BackgroundType
    var bgColor: String  // hex
    var backgroundImageName: String?
    var backgroundDimOpacity: Double

    // Colors (hex strings)
    var ink: String
    var ink2: String
    var ink3: String
    var accent: String
    var accent2: String
    var accentSoft: String
    var onAccent: String
    var surface: String
    var surface2: String
    var line: String
    var sage: String

    // Typography
    var uiFontFamily: String
    var titleFontFamily: String

    // Layout
    var cardCornerRadius: Double
    var cardBorderStyle: CardBorderStyle

    // Reader overrides
    var readerBgColor: String?
    var readerInkColor: String?

    var isDark: Bool
}
