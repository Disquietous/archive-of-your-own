import Foundation

enum ThemeImportExport {
    static func exportTheme(_ theme: ThemeDefinition) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(theme)
    }

    static func importTheme(from data: Data) -> ThemeDefinition? {
        let decoder = JSONDecoder()
        guard var theme = try? decoder.decode(ThemeDefinition.self, from: data) else {
            return nil
        }
        // Force a new identity and mark as user-created
        theme.id = UUID().uuidString
        theme.isBuiltIn = false
        return theme
    }
}
