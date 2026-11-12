import Foundation
import CoreText
import UIKit
import Observation

/// Font getters participate in SwiftUI observation. Changing a font redraws
/// text while preserving view identity, sheets and unsaved settings drafts.
@Observable
final class FontAppearance {
    static let shared = FontAppearance()
    private(set) var revision = 0
    func invalidate() { revision += 1 }
}

// Which typeface the whole app uses: the bundled Noto Serif SC, the system's
// PingFang SC, or a font the user imported from Files. Imported files are copied
// into the app's own storage and registered for this process at every launch.
enum FontChoice: String, CaseIterable, Identifiable, Sendable {
    case builtIn, system, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .builtIn: return "内置宋体"
        case .system: return "系统字体"
        case .custom: return "自定义字体"
        }
    }
}

enum FontLibrary {
    static let choiceKey = "qingjian.font.choice"
    static let revisionKey = "qingjian.font.revision"
    private static let regularKey = "qingjian.font.customRegular"
    private static let boldKey = "qingjian.font.customBold"
    private static let legacySerifKey = "qingjian.reading.serif"
    static let sizeLimit = 60 * 1024 * 1024

    static var choice: FontChoice {
        _ = FontAppearance.shared.revision
        if let raw = UserDefaults.standard.string(forKey: choiceKey), let value = FontChoice(rawValue: raw) {
            return value == .custom && regularName == nil ? .system : value
        }
        // Default to clean system font (PingFang SC + SF Pro) matching Claude Code unless legacy serif was explicitly set.
        return UserDefaults.standard.object(forKey: legacySerifKey) as? Bool == true ? .builtIn : .system
    }
    static var regularName: String? { UserDefaults.standard.string(forKey: regularKey) }
    static var boldName: String? { UserDefaults.standard.string(forKey: boldKey) }

    private static var directory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QingJian/Fonts", isDirectory: true)
    }

    /// Registers the imported fonts; call once at launch before any view draws.
    static func registerSaved() {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        // A file that went missing must not leave a name pointing nowhere.
        if let name = regularName, UIFont(name: name, size: 12) == nil { UserDefaults.standard.removeObject(forKey: regularKey) }
        if let name = boldName, UIFont(name: name, size: 12) == nil { UserDefaults.standard.removeObject(forKey: boldKey) }
    }

    /// Copies a picked .ttf/.otf in, registers it and remembers it as the regular or bold face.
    /// Returns the font's name for display.
    @discardableResult
    static func importFont(from source: URL, bold: Bool) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard ["ttf", "otf"].contains(ext) else { throw FontImportError.unsupported }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= sizeLimit else { throw FontImportError.tooLarge }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(source as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else { throw FontImportError.unreadable }
        guard let directory else { throw FontImportError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent((bold ? "bold." : "regular.") + ext)
        // Replace the previous file in this slot.
        for old in ["ttf", "otf"].map({ directory.appendingPathComponent((bold ? "bold." : "regular.") + $0) })
        where FileManager.default.fileExists(atPath: old.path) {
            CTFontManagerUnregisterFontsForURL(old as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: old)
        }
        try FileManager.default.copyItem(at: source, to: target)
        // Registering a face that is already active (the same font again) is fine: it is already usable.
        CTFontManagerRegisterFontsForURL(target as CFURL, .process, nil)
        guard UIFont(name: name, size: 12) != nil else {
            try? FileManager.default.removeItem(at: target)
            throw FontImportError.unreadable
        }
        UserDefaults.standard.set(name, forKey: bold ? boldKey : regularKey)
        if !bold { UserDefaults.standard.set(FontChoice.custom.rawValue, forKey: choiceKey) }
        bumpRevision()
        return name
    }

    static func removeCustomFonts() {
        if let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files {
                CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
                try? FileManager.default.removeItem(at: file)
            }
        }
        UserDefaults.standard.removeObject(forKey: regularKey)
        UserDefaults.standard.removeObject(forKey: boldKey)
        if choice == .custom { UserDefaults.standard.set(FontChoice.builtIn.rawValue, forKey: choiceKey) }
        bumpRevision()
    }

    static func bumpRevision() {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }

    /// 1.27: the look is reset once to the system font at 17 pt, the size Apple uses for
    /// body text, so every screen starts from the same tuned type. Both can be changed
    /// again in Settings afterwards; this never runs a second time.
    static func applyReadingDefaultsOnce() {
        let key = "sermo.typography.defaults.v127"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(FontChoice.system.rawValue, forKey: choiceKey)
        UserDefaults.standard.set(17.0, forKey: "qingjian.reading.size")
        UserDefaults.standard.set(true, forKey: key)
        bumpRevision()
    }

    /// True when text should use the real system font (SF for Latin and digits,
    /// PingFang for Chinese, with the system's own optical sizing), not a named face.
    static var usesSystemFace: Bool { InterfaceStyle.isSwiss || choice == .system }

    // Names TypeScale and ReadingStyle draw with. The Swiss look always uses the
    // system sans (PingFang SC); the chosen font comes back with the paper look.
    static var regularFace: String {
        if InterfaceStyle.isSwiss { return "PingFangSC-Regular" }
        switch choice {
        case .builtIn: return "NotoSerifSC-Regular"
        case .system: return "PingFangSC-Regular"
        case .custom: return regularName ?? "NotoSerifSC-Regular"
        }
    }
    static var boldFace: String {
        if InterfaceStyle.isSwiss { return "PingFangSC-Semibold" }
        switch choice {
        case .builtIn: return "NotoSerifSC-Bold"
        case .system: return "PingFangSC-Semibold"
        case .custom: return boldName ?? regularName ?? "NotoSerifSC-Bold"
        }
    }
}

enum FontImportError: LocalizedError {
    case unsupported, tooLarge, unreadable
    var errorDescription: String? {
        switch self {
        case .unsupported: return "请选择 .ttf 或 .otf 字体文件。"
        case .tooLarge: return "字体文件超过 60 MB。"
        case .unreadable: return "这个文件读不出字体，可能已损坏或格式不受支持。"
        }
    }
}
