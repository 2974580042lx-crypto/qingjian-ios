import UIKit
import ImageIO
import Photos

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

    static func prepared(file url: URL) throws -> Data {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 40 * 1024 * 1024 else {
            throw ChatError.server("图片超过 40 MB 或无法确定大小，请选择压缩后的照片。")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = resized(source, maxPixel: maxPixel),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.78) else {
            throw ChatError.server("无法读取这张图片，请换一张普通照片或截图。")
        }
        return jpeg
    }

    static func save(_ jpeg: Data) throws -> String {
        let name = UUID().uuidString + ".jpg"
        let folder = try directory()
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        try jpeg.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }

    static func storageStats() -> (count: Int, bytes: Int64) {
        guard let folder = try? directory(),
              let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return (0, 0)
        }
        var count = 0
        var total: Int64 = 0
        for url in urls where isSafe(url.lastPathComponent) {
            count += 1
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (count, total)
    }

    static func jpegData(named name: String) -> Data? {
        guard isSafe(name), let url = try? directory().appendingPathComponent(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func dataURL(named name: String) -> String? {
        guard let data = jpegData(named: name) else { return nil }
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

/// Ephemeral cache for AI-generated images: lives strictly under `Library/Caches/`,
/// never enters `conversations.json`, `.sermobackup`, or Google Drive backups.
/// Users manually save any desired image to the system Photos library.
enum EphemeralGeneratedImageCache {
    private static let maxCachedFiles = 40
    private static let maxAgeSeconds: TimeInterval = 7 * 24 * 3600

    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SermoGeneratedImages", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func save(base64 raw: String) -> URL? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = cleaned.firstIndex(of: ","), cleaned.prefix(32).lowercased().contains("base64") {
            cleaned = String(cleaned[cleaned.index(after: comma)...])
        }
        guard let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters),
              !data.isEmpty, UIImage(data: data) != nil,
              let folder = try? directory() else { return nil }
        let file = folder.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try data.write(to: file, options: .atomic)
            pruneIfNeeded(in: folder)
            return file
        } catch {
            return nil
        }
    }

    static func pruneIfNeeded(in folder: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let now = Date()
        let sorted = items.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d0 > d1
        }
        for (idx, url) in sorted.enumerated() {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if idx >= maxCachedFiles || now.timeIntervalSince(date) > maxAgeSeconds {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func saveToPhotos(_ url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ChatError.server("图片已过期或无法读取，请重新生成后再保存。")
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ChatError.server("请在 iPhone「设置 → Sermo → 照片」中允许添加照片。")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
    }
}
