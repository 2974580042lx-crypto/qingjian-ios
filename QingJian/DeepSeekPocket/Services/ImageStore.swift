import UIKit
import ImageIO

// Chat pictures live beside conversations.json; messages only keep file names.
// The legacy chat JSON does not contain pictures; study backups include entities.
enum ImageStore {
    static let maxPixel = 1280
    private static let thumbnails = NSCache<NSString, UIImage>()

    static func directory() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QingJian", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func isSafe(_ name: String) -> Bool {
        StudyBackupCodec.safeImageName(name)
    }
    static func clearThumbnails() { thumbnails.removeAllObjects() }

    private static func resized(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary)
    }

    // Downscale before upload: the model caps what it reads from one picture anyway.
    static func prepared(_ data: Data) throws -> Data {
        guard data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = resized(source, maxPixel: maxPixel),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.78) else {
            throw ChatError.server("无法读取这张图片，请换一张普通照片或截图。")
        }
        return jpeg
    }

    static func save(_ jpeg: Data) throws -> String {
        let name = UUID().uuidString + ".jpg"
        try jpeg.write(to: directory().appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        return name
    }

    static func dataURL(named name: String) -> String? {
        guard isSafe(name), let url = try? directory().appendingPathComponent(name),
              let data = try? Data(contentsOf: url) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    static func thumbnail(named name: String) -> UIImage? {
        if let cached = thumbnails.object(forKey: name as NSString) { return cached }
        guard isSafe(name), let url = try? directory().appendingPathComponent(name),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = resized(source, maxPixel: 520) else { return nil }
        let image = UIImage(cgImage: cg)
        thumbnails.setObject(image, forKey: name as NSString)
        return image
    }

    static func remove(_ names: [String]) {
        guard let folder = try? directory() else { return }
        for name in names where isSafe(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            thumbnails.removeObject(forKey: name as NSString)
        }
    }
}
