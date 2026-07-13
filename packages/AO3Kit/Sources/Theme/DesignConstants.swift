import SwiftUI

enum Radius {
    static let card: CGFloat = 18
    static let sheet: CGFloat = 26
    static let chip: CGFloat = 999
    static let button: CGFloat = 15
    static let smallButton: CGFloat = 12
    static let iconButton: CGFloat = 12
    static let searchField: CGFloat = 14
    static let settingsGroup: CGFloat = 16
    static let statGrid: CGFloat = 16
    static let summaryBox: CGFloat = 16
    static let chapterNum: CGFloat = 9
    static let toggle: CGFloat = 999
    static let fontOpt: CGFloat = 14
    static let themeOpt: CGFloat = 14
    static let collectionCard: CGFloat = 16
    static let resumeCard: CGFloat = 22
}

enum Density: String, CaseIterable {
    case compact, regular, comfy

    var pad: CGFloat {
        switch self {
        case .compact: 13
        case .regular: 17
        case .comfy: 21
        }
    }

    var rowGap: CGFloat {
        switch self {
        case .compact: 9
        case .regular: 13
        case .comfy: 18
        }
    }

    var cardPad: CGFloat {
        switch self {
        case .compact: 13
        case .regular: 16
        case .comfy: 20
        }
    }

    var readMargin: CGFloat {
        switch self {
        case .compact: 22
        case .regular: 26
        case .comfy: 33
        }
    }

    var readLeading: CGFloat {
        switch self {
        case .compact: 1.52
        case .regular: 1.72
        case .comfy: 1.92
        }
    }
}

enum Typography {
    static func wordmark() -> Font {
        .custom("Newsreader", size: 26).weight(.medium)
    }

    static func pageTitle() -> Font {
        .custom("Newsreader", size: 33).weight(.medium)
    }

    static func browseTitle() -> Font {
        .custom("Newsreader", size: 26).weight(.medium)
    }

    static func detailTitle() -> Font {
        .custom("Newsreader", size: 30).weight(.semibold)
    }

    static func readerChTitle() -> Font {
        .custom("Newsreader", size: 26).weight(.semibold)
    }

    static func workTitle() -> Font {
        .custom("Newsreader", size: 18.5).weight(.semibold)
    }

    static func resumeTitle() -> Font {
        .custom("Newsreader", size: 23).weight(.semibold)
    }

    static func summaryBody() -> Font {
        .custom("Newsreader", size: 16)
    }

    static func summaryBodyItalic() -> Font {
        .custom("Newsreader-Italic", size: 16)
    }

    static func sheetTitle() -> Font {
        .custom("Newsreader", size: 22).weight(.semibold)
    }

    static func emptyTitle() -> Font {
        .custom("Newsreader", size: 19).weight(.semibold)
    }

    static func uiBody() -> Font {
        .custom("HankenGrotesk", size: 15).weight(.medium)
    }

    static func uiCaption() -> Font {
        .custom("HankenGrotesk", size: 13).weight(.semibold)
    }

    static func uiSmall() -> Font {
        .custom("HankenGrotesk", size: 12).weight(.semibold)
    }

    static func sectionHeader() -> Font {
        .custom("HankenGrotesk", size: 13).weight(.bold)
    }

    static func buttonLabel() -> Font {
        .custom("HankenGrotesk", size: 16).weight(.bold)
    }

    static func smallButtonLabel() -> Font {
        .custom("HankenGrotesk", size: 14.5).weight(.bold)
    }

    static func segControl() -> Font {
        .custom("HankenGrotesk", size: 13.5).weight(.semibold)
    }

    static func tabLabel() -> Font {
        .custom("HankenGrotesk", size: 10.5).weight(.semibold)
    }

    static func readingBody(fontName: String, size: CGFloat) -> Font {
        .custom(fontName, size: size)
    }
}
