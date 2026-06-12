import SwiftUI

enum Rating: String, CaseIterable, Hashable {
    case general = "General"
    case teen = "Teen"
    case mature = "Mature"
    case explicit = "Explicit"

    var letter: String {
        switch self {
        case .general: "G"
        case .teen: "T"
        case .mature: "M"
        case .explicit: "E"
        }
    }

    var badgeColor: Color {
        switch self {
        case .general: Color(hex: "63A471")
        case .teen: Color(hex: "B49D46")
        case .mature: Color(hex: "CE7A3B")
        case .explicit: Color(hex: "CE514D")
        }
    }
}

enum ArchiveWarning: String, Hashable {
    case none = "No Archive Warnings Apply"
    case chooseNot = "Choose Not To Use Archive Warnings"
}
