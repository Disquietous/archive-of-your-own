import SwiftUI

enum ReadingFont: String, CaseIterable {
    case newsreader = "Newsreader"
    case literata = "Literata"
    case lora = "Lora"
    case hankenGrotesk = "HankenGrotesk"

    var displayName: String {
        switch self {
        case .newsreader: "Newsreader"
        case .literata: "Literata"
        case .lora: "Lora"
        case .hankenGrotesk: "Hanken Grotesk"
        }
    }

    var kind: String {
        switch self {
        case .hankenGrotesk: "Sans"
        default: "Serif"
        }
    }

    var fontName: String { rawValue }
}

@Observable
final class AppTheme {
    var activeTheme: ThemeDefinition {
        didSet {
            UserDefaults.standard.set(activeTheme.id, forKey: "activeThemeId")
            _backgroundImage = nil
            _backgroundImageLoaded = false
        }
    }

    var readingFont: ReadingFont {
        didSet { UserDefaults.standard.set(readingFont.rawValue, forKey: "readingFont") }
    }
    var fontSize: Int {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    var density: Density {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "density") }
    }
    var requestTimeout: Int {
        didSet { UserDefaults.standard.set(requestTimeout, forKey: "requestTimeout") }
    }
    var useTorByDefault: Bool {
        didSet { UserDefaults.standard.set(useTorByDefault, forKey: "useTorByDefault") }
    }

    // Lazy-loaded background image
    private var _backgroundImage: PlatformImage?
    private var _backgroundImageLoaded = false

    var backgroundImage: PlatformImage? {
        if !_backgroundImageLoaded {
            _backgroundImageLoaded = true
            if let name = activeTheme.backgroundImageName {
                _backgroundImage = BackgroundImageManager.loadImage(name: name)
            }
        }
        return _backgroundImage
    }

    init() {
        let d = UserDefaults.standard

        // Migration: convert old themeMode to activeThemeId
        if d.string(forKey: "activeThemeId") == nil,
           let oldMode = d.string(forKey: "themeMode") {
            let migratedTheme: ThemeDefinition
            switch oldMode {
            case "paper", "light":
                migratedTheme = PresetThemes.paper
            case "sepia", "warm":
                migratedTheme = PresetThemes.sepia
            case "dark":
                migratedTheme = PresetThemes.night
            default:
                migratedTheme = PresetThemes.paper
            }
            d.set(migratedTheme.id, forKey: "activeThemeId")
        }

        // Load active theme from persisted ID
        let themeId = d.string(forKey: "activeThemeId") ?? PresetThemes.paper.id
        activeTheme = PresetThemes.all.first { $0.id == themeId } ?? PresetThemes.paper

        readingFont = ReadingFont(rawValue: d.string(forKey: "readingFont") ?? "") ?? .newsreader
        fontSize = d.object(forKey: "fontSize") as? Int ?? 19
        density = Density(rawValue: d.string(forKey: "density") ?? "") ?? .regular
        requestTimeout = d.object(forKey: "requestTimeout") as? Int ?? 30
        useTorByDefault = d.bool(forKey: "useTorByDefault")
    }

    // MARK: - Theme switching

    func switchTheme(_ theme: ThemeDefinition) {
        activeTheme = theme
    }

    func updateActiveTheme(_ modifier: (inout ThemeDefinition) -> Void) {
        var theme = activeTheme
        modifier(&theme)
        activeTheme = theme
    }

    func loadActiveTheme(from bridge: RustBridge) {
        // For now, presets are loaded from UserDefaults (done in init).
        // When custom themes from DB are supported, load them here.
        let d = UserDefaults.standard
        let themeId = d.string(forKey: "activeThemeId") ?? PresetThemes.paper.id
        if let found = PresetThemes.all.first(where: { $0.id == themeId }) {
            activeTheme = found
        }
    }

    // MARK: - Color computed properties (from activeTheme hex values)

    var bg: Color { Color(hex: activeTheme.bgColor) }
    var surface: Color { Color(hex: activeTheme.surface) }
    var surface2: Color { Color(hex: activeTheme.surface2) }
    var ink: Color { Color(hex: activeTheme.ink) }
    var ink2: Color { Color(hex: activeTheme.ink2) }
    var ink3: Color { Color(hex: activeTheme.ink3) }
    var line: Color { Color(hex: activeTheme.line) }
    var accent: Color { Color(hex: activeTheme.accent) }
    var accent2: Color { Color(hex: activeTheme.accent2) }
    var accentSoft: Color { Color(hex: activeTheme.accentSoft) }
    var onAccent: Color { Color(hex: activeTheme.onAccent) }
    var sage: Color { Color(hex: activeTheme.sage) }

    // Derived colors (not in ThemeDefinition, derived from theme tokens)
    var surface3: Color {
        // Slightly darker/more saturated than surface2
        if activeTheme.isDark {
            return Color(hex: activeTheme.surface2).opacity(1).blendedWith(Color(hex: activeTheme.line), fraction: 0.3)
        } else {
            return Color(hex: activeTheme.surface2).blendedWith(Color(hex: activeTheme.bgColor), fraction: 0.3)
        }
    }

    var line2: Color {
        // A secondary line color, slightly stronger than line
        if activeTheme.isDark {
            return Color(hex: activeTheme.line).blendedWith(Color(hex: activeTheme.ink3), fraction: 0.25)
        } else {
            return Color(hex: activeTheme.line).blendedWith(Color(hex: activeTheme.ink3), fraction: 0.15)
        }
    }

    // MARK: - Typography properties from theme

    var uiFontFamily: String { activeTheme.uiFontFamily }
    var titleFontFamily: String { activeTheme.titleFontFamily }

    // MARK: - Layout properties from theme

    var cardCornerRadius: CGFloat { CGFloat(activeTheme.cardCornerRadius) }
    var cardBorderStyle: CardBorderStyle { activeTheme.cardBorderStyle }

    // MARK: - Density-derived layout

    var pad: CGFloat { density.pad }
    var rowGap: CGFloat { density.rowGap }
    var cardPad: CGFloat { density.cardPad }
    var readMargin: CGFloat { density.readMargin }
    var readLeading: CGFloat { density.readLeading }

    // MARK: - Reading

    var readingBodyFont: Font {
        Typography.readingBody(fontName: readingFont.fontName, size: CGFloat(fontSize))
    }

    var readingLineSpacing: CGFloat {
        CGFloat(fontSize) * (readLeading - 1)
    }

    // MARK: - Color scheme

    var preferredColorScheme: ColorScheme? {
        activeTheme.isDark ? .dark : .light
    }
}

// MARK: - Color blending helper

private extension Color {
    func blendedWith(_ other: Color, fraction: Double) -> Color {
        let (r1, g1, b1, _) = rgbaComponents()
        let (r2, g2, b2, _) = other.rgbaComponents()
        return Color(
            red: r1 + (r2 - r1) * fraction,
            green: g1 + (g2 - g1) * fraction,
            blue: b1 + (b2 - b1) * fraction
        )
    }
}
