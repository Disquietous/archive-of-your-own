import AppKit
import SwiftUI

/// Design-token access for AppKit views. Colors come from the shared AppTheme;
/// the two sidebar tints are derived (the handoff defines them as slightly
/// deeper takes on the pane background).
extension AppTheme {
    var nsBg: NSColor { NSColor(bg) }
    var nsSurface: NSColor { NSColor(surface) }
    var nsSurface2: NSColor { NSColor(surface2) }
    var nsSurface3: NSColor { NSColor(surface3) }
    var nsInk: NSColor { NSColor(ink) }
    var nsInk2: NSColor { NSColor(ink2) }
    var nsInk3: NSColor { NSColor(ink3) }
    var nsLine: NSColor { NSColor(line) }
    var nsLine2: NSColor { NSColor(line2) }
    var nsAccent: NSColor { NSColor(accent) }
    var nsAccentSoft: NSColor { NSColor(accentSoft) }
    var nsOnAccent: NSColor { NSColor(onAccent) }
    var nsSage: NSColor { NSColor(sage) }

    /// Sidebar fill — between bg and surface-3, leaning darker than the panes.
    var sidebarFill: Color {
        isDarkTheme ? bg.blended(with: .black, fraction: 0.16) : bg.blended(with: ink, fraction: 0.045)
    }
    var sidebarHover: Color {
        isDarkTheme ? bg.blended(with: .white, fraction: 0.06) : bg.blended(with: ink, fraction: 0.09)
    }
    var isDarkTheme: Bool { activeTheme.isDark }
}

extension Color {
    func blended(with other: Color, fraction: Double) -> Color {
        let (r1, g1, b1, _) = rgbaComponents()
        let (r2, g2, b2, _) = other.rgbaComponents()
        return Color(
            red: r1 + (r2 - r1) * fraction,
            green: g1 + (g2 - g1) * fraction,
            blue: b1 + (b2 - b1) * fraction
        )
    }
}

/// NSTableView that reports Return/Enter so lists can open the selected row;
/// ↑/↓ selection comes from AppKit once the table is first responder.
final class KeyNavTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let onReturn {
            onReturn()
            return
        }
        super.keyDown(with: event)
    }
}

/// Font helpers matching the handoff: Hanken Grotesk for UI, the user's
/// reading serif for titles/body. Fall back to system fonts if the bundled
/// faces fail to load.
enum MacFont {
    /// App-chrome text scale (Settings → App text size). Synced from
    /// AppTheme.uiFontScale at launch and when the setting changes. Applies
    /// to ui/serif chrome fonts only — reading fonts have their own size.
    static var scale: CGFloat = 1

    static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let size = size * scale
        if let font = NSFont(name: "Hanken Grotesk", size: size) ?? NSFont(name: "HankenGrotesk", size: size) {
            return weight == .regular ? font : withWeight(font, weight)
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let size = size * scale
        if let font = NSFont(name: "Newsreader", size: size) {
            return weight == .regular ? font : withWeight(font, weight)
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }

    static func reading(named name: String, size: CGFloat) -> NSFont {
        if let font = NSFont(name: name, size: size) { return font }
        // Unscaled serif fallback — reading text size is user-controlled
        // directly and must not compound with the app-chrome scale.
        let base = NSFont.systemFont(ofSize: size)
        if let descriptor = base.fontDescriptor.withDesign(.serif),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }

    /// Variable fonts: select a weight via the variation axis when possible.
    static func withWeight(_ font: NSFont, _ weight: NSFont.Weight) -> NSFont {
        let wghtAxisID = 0x77676874 // 'wght'
        let value: CGFloat = switch weight {
        case .bold, .heavy, .black: 700
        case .semibold: 600
        case .medium: 500
        default: 400
        }
        let descriptor = font.fontDescriptor.addingAttributes([
            kCTFontVariationAttribute as NSFontDescriptor.AttributeName: [wghtAxisID: value],
        ])
        if let varied = NSFont(descriptor: descriptor, size: font.pointSize) { return varied }
        let traits = font.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: traits, size: font.pointSize) ?? font
    }
}

/// Re-runs `apply` whenever any @Observable property it reads changes.
/// Lives for the lifetime of the owning view/controller.
enum ObservationRelay {
    static func track(_ apply: @escaping () -> Void) {
        withObservationTracking {
            apply()
        } onChange: {
            DispatchQueue.main.async { track(apply) }
        }
    }
}
