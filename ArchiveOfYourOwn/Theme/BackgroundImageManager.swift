import UIKit

enum BackgroundImageManager {
    private static var backgroundsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("ArchiveOfYourOwn", isDirectory: true)
            .appendingPathComponent("ThemeBackgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func saveImage(_ image: UIImage, name: String) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let filename = name.hasSuffix(".jpg") ? name : "\(name).jpg"
        let url = backgroundsDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    static func loadImage(name: String) -> UIImage? {
        let url = backgroundsDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func deleteImage(name: String) {
        let url = backgroundsDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }
}
