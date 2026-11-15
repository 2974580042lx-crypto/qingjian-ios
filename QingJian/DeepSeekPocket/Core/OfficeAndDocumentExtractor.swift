import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Extracts plain text from Office Open XML (`.docx`, `.xlsx`, `.pptx`), `.rtf`, `.epub`,
/// and binary `.plist` files without any third-party dependencies.
enum OfficeAndDocumentExtractor {
    static func extractDOCX(_ data: Data) throws -> String {
        let reader = try StreamZipReader(data: data)
        guard let docEntry = reader.entry(named: "word/document.xml") else {
            throw ImportFailure("这个 DOCX 文件缺少正文内容（word/document.xml）。")
        }
        let xmlData = try reader.readEntry(docEntry)
        let text = DOCXParser(data: xmlData).parse().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportFailure("这个 DOCX 文件没有读出可提取的文字。") }
        return text
    }

    static func extractXLSX(_ data: Data) throws -> String {
        let reader = try StreamZipReader(data: data)
        var sharedStrings: [String] = []
        if let ssEntry = reader.entry(named: "xl/sharedStrings.xml"),
           let ssData = try? reader.readEntry(ssEntry) {
            sharedStrings = XLSXSharedStringsParser(data: ssData).parse()
        }

        var sheetNames: [String] = []
        if let wbEntry = reader.entry(named: "xl/workbook.xml"),
           let wbData = try? reader.readEntry(wbEntry) {
            sheetNames = XLSXWorkbookParser(data: wbData).parse()
        }

        let sheetEntries = reader.entries
            .filter { !$0.isDirectory && $0.name.lowercased().hasPrefix("xl/worksheets/sheet") && $0.name.lowercased().hasSuffix(".xml") }
            .sorted { numericOrder($0.name) < numericOrder($1.name) }

        guard !sheetEntries.isEmpty else {
            throw ImportFailure("这个 XLSX 文件里没有找到工作表。")
        }

        var sections: [String] = []
        for (idx, entry) in sheetEntries.enumerated() {
            guard let sheetData = try? reader.readEntry(entry) else { continue }
            let rows = XLSXSheetParser(data: sheetData, sharedStrings: sharedStrings).parse()
            let nonEmptyRows = rows.filter { !$0.allSatisfy { $0.isEmpty } }
            guard !nonEmptyRows.isEmpty else { continue }
            let title = idx < sheetNames.count ? sheetNames[idx] : "工作表 \(idx + 1)"
            let body = nonEmptyRows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            sections.append("## \(title)\n\(body)")
        }

        let joined = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw ImportFailure("这个 XLSX 文件没有读出可提取的单元格文字。") }
        return joined
    }

    static func extractPPTX(_ data: Data) throws -> String {
        let reader = try StreamZipReader(data: data)
        let slideEntries = reader.entries
            .filter { !$0.isDirectory && $0.name.lowercased().hasPrefix("ppt/slides/slide") && $0.name.lowercased().hasSuffix(".xml") }
            .sorted { numericOrder($0.name) < numericOrder($1.name) }

        guard !slideEntries.isEmpty else {
            throw ImportFailure("这个 PPTX 文件里没有找到幻灯片页面。")
        }

        let notesEntries = reader.entries
            .filter { !$0.isDirectory && $0.name.lowercased().hasPrefix("ppt/notesslides/notesslide") && $0.name.lowercased().hasSuffix(".xml") }
        let notesMap = Dictionary(uniqueKeysWithValues: notesEntries.map { (numericOrder($0.name), $0) })

        var pages: [String] = []
        for (idx, entry) in slideEntries.enumerated() {
            let slideNum = numericOrder(entry.name)
            var lines: [String] = []
            if let slideData = try? reader.readEntry(entry) {
                let text = PPTXSlideParser(data: slideData).parse().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
            }
            if let noteEntry = notesMap[slideNum],
               let noteData = try? reader.readEntry(noteEntry) {
                let noteText = PPTXSlideParser(data: noteData).parse().trimmingCharacters(in: .whitespacesAndNewlines)
                if !noteText.isEmpty { lines.append("【备注】\n\(noteText)") }
            }
            if !lines.isEmpty {
                pages.append("## 第 \(idx + 1) 页\n" + lines.joined(separator: "\n\n"))
            }
        }

        let joined = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw ImportFailure("这个 PPTX 文件没有读出可提取的文字。") }
        return joined
    }

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

    static func extractEPUB(_ data: Data) throws -> (title: String?, text: String) {
        let parsed = try EpubBook.pages(from: data)
        let body = parsed.pages.map { page in
            if let title = page.title, !title.isEmpty, !page.text.hasPrefix(title) {
                return "## \(title)\n\(page.text)"
            }
            return page.text
        }.joined(separator: "\n\n")
        return (parsed.title, body)
    }

    static func decodeBinaryPlist(_ data: Data) throws -> String {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let xmlData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        guard let xml = String(data: xmlData, encoding: .utf8), !xml.isEmpty else {
            throw ImportFailure("二进制 plist 转换文本失败。")
        }
        return xml
    }

    private static func numericOrder(_ path: String) -> Int {
        let digits = path.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits) ?? 0
    }
}

// MARK: - XML Parsers

private final class DOCXParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var output = ""
    private var inText = false
    private var inRow = false
    private var firstCellInRow = true

    init(data: Data) { self.data = data }

    func parse() -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return output
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = localName(elementName)
        switch local {
        case "t", "delText":
            inText = true
        case "tab":
            output += "\t"
        case "br", "cr":
            output += "\n"
        case "tr":
            inRow = true
            firstCellInRow = true
        case "tc":
            if inRow && !firstCellInRow { output += "\t" }
            firstCellInRow = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { output += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        switch local {
        case "t", "delText":
            inText = false
        case "p":
            if !output.hasSuffix("\n") && !output.hasSuffix("\t") { output += "\n" }
        case "tr":
            inRow = false
            if !output.hasSuffix("\n") { output += "\n" }
        default:
            break
        }
    }
}

private final class XLSXSharedStringsParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var strings: [String] = []
    private var current = ""
    private var inSI = false
    private var inT = false

    init(data: Data) { self.data = data }

    func parse() -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = localName(elementName)
        if local == "si" {
            inSI = true
            current = ""
        } else if inSI && local == "t" {
            inT = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        if local == "t" { inT = false }
        else if local == "si" {
            inSI = false
            strings.append(current)
        }
    }
}

private final class XLSXWorkbookParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var names: [String] = []

    init(data: Data) { self.data = data }

    func parse() -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return names
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if localName(elementName) == "sheet", let name = attributeDict["name"], !name.isEmpty {
            names.append(name)
        }
    }
}

private final class XLSXSheetParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let sharedStrings: [String]
    private var rows: [[String]] = []
    private var currentRow: [String] = []
    private var cellType = ""
    private var cellValue = ""
    private var inValue = false
    private var inInlineText = false

    init(data: Data, sharedStrings: [String]) {
        self.data = data
        self.sharedStrings = sharedStrings
    }

    func parse() -> [[String]] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = localName(elementName)
        switch local {
        case "row":
            currentRow = []
        case "c":
            cellType = attributeDict["t"] ?? ""
            cellValue = ""
        case "v":
            inValue = true
        case "t":
            if cellType == "inlineStr" { inInlineText = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue || inInlineText { cellValue += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        switch local {
        case "v":
            inValue = false
        case "t":
            inInlineText = false
        case "c":
            if cellType == "s", let index = Int(cellValue.trimmingCharacters(in: .whitespacesAndNewlines)),
               index >= 0, index < sharedStrings.count {
                currentRow.append(sharedStrings[index])
            } else {
                currentRow.append(cellValue)
            }
        case "row":
            rows.append(currentRow)
        default:
            break
        }
    }
}

private final class PPTXSlideParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var output = ""
    private var inText = false

    init(data: Data) { self.data = data }

    func parse() -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return output
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = localName(elementName)
        if local == "t" { inText = true }
        else if local == "br" { output += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { output += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        if local == "t" { inText = false }
        else if local == "p" && !output.hasSuffix("\n") { output += "\n" }
    }
}

private func localName(_ elementName: String) -> String {
    if let colon = elementName.lastIndex(of: ":") {
        return String(elementName[elementName.index(after: colon)...])
    }
    return elementName
}
