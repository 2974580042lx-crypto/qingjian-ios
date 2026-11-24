import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension OfficeAndDocumentExtractor {
    static func extractRTF(_ data: Data) throws -> String {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else {
            throw ImportFailure("无法读取这个 RTF 文件。")
        }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportFailure("这个 RTF 文件没有可提取的文字。") }
        return text
    }
}
