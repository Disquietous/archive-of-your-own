import SwiftUI
import ImageIO

enum BackgroundImageManager {
    /// Longest side a stored background needs: the largest screen's
    /// longest side in pixels. A photo straight from a camera is several
    /// times that, and it was decoded and composited at full size behind
    /// every screen for no visible gain.
    private static var maxPixelSize: CGFloat {
        #if canImport(UIKit)
        let bounds = UIScreen.main.bounds.size
        return max(bounds.width, bounds.height) * UIScreen.main.scale
        #else
        return NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 2560
        #endif
    }

    /// `data` re-encoded with its longest side at most `maxPixelSize`, or
    /// nil when it already fits (or can't be read).
    private static func downsampled(_ data: Data, maxPixelSize: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
              max(width, height) > maxPixelSize else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static var backgroundsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("ArchiveOfYourOwn", isDirectory: true)
            .appendingPathComponent("ThemeBackgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func saveImage(_ image: PlatformImage, name: String) -> String? {
        guard let encoded = image.jpegEncoded(compressionQuality: 0.85) else { return nil }
        let data = downsampled(encoded, maxPixelSize: maxPixelSize) ?? encoded
        let filename = name.hasSuffix(".jpg") ? name : "\(name).jpg"
        let url = backgroundsDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    static func loadImage(name: String) -> PlatformImage? {
        let url = backgroundsDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return PlatformImage(data: data)
    }

    static func deleteImage(name: String) {
        let url = backgroundsDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }
}
