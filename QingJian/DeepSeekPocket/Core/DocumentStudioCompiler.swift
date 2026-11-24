import Foundation
import Compression
import CoreGraphics
import CoreText

struct DocxFootnote: Codable, Equatable, Sendable {
    var id: Int
    var text: String
}

struct DocxDocumentSpec: Equatable, Sendable {
    var title: String
    var markdown: String
    var explicitFootnotes: [DocxFootnote] = []
    var useCircledNumbers: Bool = true
    var restartFootnotesPerPage: Bool = true
}

struct DocxCompiledResult: Sendable {
    let data: Data
    let footnoteCount: Int
    let characterCount: Int
}

struct XlsxSheetSpec: Codable, Equatable, Sendable {
    var name: String
    var headers: [String]
    var rows: [[String]]
}

struct XlsxWorkbookSpec: Codable, Equatable, Sendable {
    var sheets: [XlsxSheetSpec]
}

struct XlsxCompiledResult: Sendable {
    let data: Data
    let sheetCount: Int
    let rowCount: Int
}

enum DocumentStudioError: LocalizedError, Equatable {
    case emptyContent
    case invalidSpecification(String)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyContent: return "文档内容为空，未能生成文件。"
        case .invalidSpecification(let detail): return detail
        case .encodingFailed(let detail): return "文件生成失败：\(detail)"
        }
    }
}

/// Pure-Swift zero-dependency PKZIP writer producing valid OPC archives for `.docx` and `.xlsx`.
enum SimpleZipWriter {
    struct Entry {
        let path: String
        let data: Data
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    static func archive(_ entries: [Entry]) throws -> Data {
        var out = Data()
        var centralDir = Data()
        var count: UInt16 = 0

        for entry in entries {
            let nameData = Data(entry.path.utf8)
            guard nameData.count <= 0xFFFF else {
                throw DocumentStudioError.encodingFailed("ZIP 条目路径过长：\(entry.path)")
            }
            let uncompressed = entry.data
            let crc = crc32(uncompressed)
            let method: UInt16
            let payload: Data
            if uncompressed.count >= 128, let deflated = rawDeflate(uncompressed), deflated.count < uncompressed.count {
                method = 8
                payload = deflated
            } else {
                method = 0
                payload = uncompressed
            }

            let localOffset = UInt32(out.count)
            // Local file header (30 bytes + filename + payload)
            appendU32(&out, 0x04034B50)
            appendU16(&out, 20)                  // version needed to extract (2.0)
            appendU16(&out, 0x0800)              // UTF-8 filename flag
            appendU16(&out, method)
            appendU16(&out, 0)                   // mod time
            appendU16(&out, 0x5421)              // mod date (2022-01-01)
            appendU32(&out, crc)
            appendU32(&out, UInt32(payload.count))
            appendU32(&out, UInt32(uncompressed.count))
            appendU16(&out, UInt16(nameData.count))
            appendU16(&out, 0)                   // extra length
            out.append(nameData)
            out.append(payload)

            // Central directory header (46 bytes + filename)
            appendU32(&centralDir, 0x02014B50)
            appendU16(&centralDir, 20)           // version made by
            appendU16(&centralDir, 20)           // version needed
            appendU16(&centralDir, 0x0800)       // UTF-8 flag
            appendU16(&centralDir, method)
            appendU16(&centralDir, 0)            // mod time
            appendU16(&centralDir, 0x5421)       // mod date
            appendU32(&centralDir, crc)
            appendU32(&centralDir, UInt32(payload.count))
            appendU32(&centralDir, UInt32(uncompressed.count))
            appendU16(&centralDir, UInt16(nameData.count))
            appendU16(&centralDir, 0)            // extra length
            appendU16(&centralDir, 0)            // comment length
            appendU16(&centralDir, 0)            // disk number
            appendU16(&centralDir, 0)            // internal attrs
            appendU32(&centralDir, 0)            // external attrs
            appendU32(&centralDir, localOffset)
            centralDir.append(nameData)

            count &+= 1
        }

        let cdOffset = UInt32(out.count)
        let cdSize = UInt32(centralDir.count)
        out.append(centralDir)

        // End of Central Directory (22 bytes)
        appendU32(&out, 0x06054B50)
        appendU16(&out, 0)                       // disk number
        appendU16(&out, 0)                       // start disk
        appendU16(&out, count)
        appendU16(&out, count)
        appendU32(&out, cdSize)
        appendU32(&out, cdOffset)
        appendU16(&out, 0)                       // comment length
        return out
    }

    private static func rawDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = max(data.count + 64, 512)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    private static func appendU16(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
    }

    private static func appendU32(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 24) & 0xFF))
    }
}

/// Zero-dependency native compiler for academic `.docx` (with real `word/footnotes.xml`),
/// multi-sheet `.xlsx`, vector Chinese `.pdf`, `.html`, and `.md` deliverables.
enum DocumentStudioCompiler {

    // MARK: - XML Helpers

    static func xmlEscape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 16)
        for scalar in text.unicodeScalars {
            // Strip illegal XML 1.0 control chars except \t, \n, \r
            let v = scalar.value
            if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D { continue }
            if v == 0xFFFE || v == 0xFFFF { continue }
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - DOCX Compiler (Standard OOXML + Real Page Footnotes)

    static func compileDOCX(_ spec: DocxDocumentSpec) throws -> DocxCompiledResult {
        let normalized = spec.markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw DocumentStudioError.emptyContent }

        // 1. Parse Markdown footnote definitions `[^key]: text`
        var footnoteByKey: [String: String] = [:]
        for explicit in spec.explicitFootnotes {
            footnoteByKey["\(explicit.id)"] = explicit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rawLines = normalized.components(separatedBy: "\n")
        var bodyLines: [String] = []
        var activeFootnoteKey: String? = nil

        for line in rawLines {
            if let def = parseFootnoteDefinition(line) {
                footnoteByKey[def.key] = def.text
                activeFootnoteKey = def.key
            } else if let key = activeFootnoteKey, (line.hasPrefix("    ") || line.hasPrefix("\t")) {
                let extra = line.trimmingCharacters(in: .whitespaces)
                if !extra.isEmpty {
                    footnoteByKey[key] = (footnoteByKey[key] ?? "") + " " + extra
                }
            } else {
                activeFootnoteKey = nil
                bodyLines.append(line)
            }
        }

        // Assign stable sequential integer IDs (1, 2, 3...) to referenced footnotes in order of appearance
        var keyToWordID: [String: Int] = [:]
        var orderedFootnotes: [DocxFootnote] = []

        func resolveFootnoteID(for key: String) -> Int? {
            guard let noteText = footnoteByKey[key], !noteText.isEmpty else { return nil }
            if let existing = keyToWordID[key] { return existing }
            let nextID = orderedFootnotes.count + 1
            keyToWordID[key] = nextID
            orderedFootnotes.append(DocxFootnote(id: nextID, text: noteText))
            return nextID
        }

        // 2. Parse body blocks (headings, paragraphs, lists, quotes, Markdown tables)
        var bodyXML = ""
        let firstNonEmpty = bodyLines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        if !spec.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !firstNonEmpty.hasPrefix("#") {
            bodyXML += docxHeadingParagraph(text: spec.title, level: 1, resolveFootnote: resolveFootnoteID)
        }

        var idx = 0
        while idx < bodyLines.count {
            let line = bodyLines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                idx += 1
                continue
            }

            // Markdown table block
            if trimmed.contains("|"), idx + 1 < bodyLines.count, isMarkdownTableSeparator(bodyLines[idx + 1]) {
                let headerCells = splitTableRow(trimmed)
                idx += 2
                var dataRows: [[String]] = []
                while idx < bodyLines.count {
                    let rowTrim = bodyLines[idx].trimmingCharacters(in: .whitespaces)
                    if rowTrim.isEmpty || !rowTrim.contains("|") { break }
                    dataRows.append(splitTableRow(rowTrim))
                    idx += 1
                }
                bodyXML += docxTable(headers: headerCells, rows: dataRows, resolveFootnote: resolveFootnoteID)
                continue
            }

            // Headings
            if trimmed.hasPrefix("#") {
                let level = min(3, max(1, trimmed.prefix(while: { $0 == "#" }).count))
                let text = String(trimmed.drop(while: { $0 == "#" || $0 == " " }))
                bodyXML += docxHeadingParagraph(text: text, level: level, resolveFootnote: resolveFootnoteID)
                idx += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                bodyXML += docxQuoteParagraph(text: text, resolveFootnote: resolveFootnoteID)
                idx += 1
                continue
            }

            // Bullet or numbered list line
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                bodyXML += docxListParagraph(marker: "• ", text: text, resolveFootnote: resolveFootnoteID)
                idx += 1
                continue
            }
            if let numbered = parseNumberedListLine(trimmed) {
                bodyXML += docxListParagraph(marker: numbered.marker + " ", text: numbered.text, resolveFootnote: resolveFootnoteID)
                idx += 1
                continue
            }

            // Regular paragraph (merge consecutive plain lines until blank or block starter)
            var paraLines = [trimmed]
            idx += 1
            while idx < bodyLines.count {
                let nextTrim = bodyLines[idx].trimmingCharacters(in: .whitespaces)
                if nextTrim.isEmpty || nextTrim.hasPrefix("#") || nextTrim.hasPrefix(">")
                    || nextTrim.hasPrefix("- ") || nextTrim.hasPrefix("* ")
                    || parseNumberedListLine(nextTrim) != nil
                    || (nextTrim.contains("|") && idx + 1 < bodyLines.count && isMarkdownTableSeparator(bodyLines[idx + 1])) {
                    break
                }
                paraLines.append(nextTrim)
                idx += 1
            }
            let paragraphText = paraLines.joined(separator: " ")
            bodyXML += docxBodyParagraph(text: paragraphText, resolveFootnote: resolveFootnoteID)
        }

        // Append any explicit footnotes not referenced inline so zero citations are lost
        for explicit in spec.explicitFootnotes {
            let key = "\(explicit.id)"
            if keyToWordID[key] == nil, !explicit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let nextID = orderedFootnotes.count + 1
                keyToWordID[key] = nextID
                orderedFootnotes.append(DocxFootnote(id: nextID, text: explicit.text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }

        let hasFootnotes = !orderedFootnotes.isEmpty
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            \(bodyXML)
            <w:sectPr>
              \(hasFootnotes ? docxFootnotePropertiesXML(circled: spec.useCircledNumbers, restartPerPage: spec.restartFootnotesPerPage) : "")
              <w:pgSz w:w="11906" w:h="16838"/>
              <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """

        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
          <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
          \(hasFootnotes ? "<Override PartName=\"/word/footnotes.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml\"/>" : "")
        </Types>
        """

        let rootRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

        let docRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
          \(hasFootnotes ? "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes\" Target=\"footnotes.xml\"/>" : "")
        </Relationships>
        """

        let stylesXML = docxStylesXML()
        let settingsXML = docxSettingsXML(hasFootnotes: hasFootnotes, circled: spec.useCircledNumbers, restartPerPage: spec.restartFootnotesPerPage)

        var entries: [SimpleZipWriter.Entry] = [
            .init(path: "[Content_Types].xml", data: Data(contentTypesXML.utf8)),
            .init(path: "_rels/.rels", data: Data(rootRelsXML.utf8)),
            .init(path: "word/document.xml", data: Data(documentXML.utf8)),
            .init(path: "word/_rels/document.xml.rels", data: Data(docRelsXML.utf8)),
            .init(path: "word/styles.xml", data: Data(stylesXML.utf8)),
            .init(path: "word/settings.xml", data: Data(settingsXML.utf8))
        ]
        if hasFootnotes {
            entries.append(.init(path: "word/footnotes.xml", data: Data(docxFootnotesXML(orderedFootnotes).utf8)))
        }

        let zipped = try SimpleZipWriter.archive(entries)
        return DocxCompiledResult(data: zipped, footnoteCount: orderedFootnotes.count, characterCount: normalized.count)
    }

    private static func docxFootnotePropertiesXML(circled: Bool, restartPerPage: Bool) -> String {
        let fmt = circled ? "decimalEnclosedCircle" : "decimal"
        let restart = restartPerPage ? "<w:numRestart w:val=\"eachPage\"/>" : ""
        return "<w:footnotePr><w:numFmt w:val=\"\(fmt)\"/>\(restart)</w:footnotePr>"
    }

    private static func docxSettingsXML(hasFootnotes: Bool, circled: Bool, restartPerPage: Bool) -> String {
        let footnotePr = hasFootnotes
            ? """
              <w:footnotePr>
                <w:numFmt w:val="\(circled ? "decimalEnclosedCircle" : "decimal")"/>
                \(restartPerPage ? "<w:numRestart w:val=\"eachPage\"/>" : "")
                <w:footnote w:id="-1"/>
                <w:footnote w:id="0"/>
              </w:footnotePr>
              """
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:zoom w:percent="100"/>
          <w:defaultTabStop w:val="420"/>
          \(footnotePr)
        </w:settings>
        """
    }

    private static func docxStylesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:docDefaults>
            <w:rPrDefault>
              <w:rPr>
                <w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="SimSun"/>
                <w:sz w:val="24"/>
                <w:szCs w:val="24"/>
                <w:color w:val="171717"/>
              </w:rPr>
            </w:rPrDefault>
            <w:pPrDefault>
              <w:pPr>
                <w:spacing w:after="160" w:line="340" w:lineRule="auto"/>
              </w:pPr>
            </w:pPrDefault>
          </w:docDefaults>
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
            <w:name w:val="Normal"/>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading1">
            <w:name w:val="heading 1"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:spacing w:before="280" w:after="180"/><w:outlineLvl w:val="0"/></w:pPr>
            <w:rPr><w:rFonts w:eastAsia="SimHei"/><w:b/><w:sz w:val="34"/><w:szCs w:val="34"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading2">
            <w:name w:val="heading 2"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:spacing w:before="240" w:after="140"/><w:outlineLvl w:val="1"/></w:pPr>
            <w:rPr><w:rFonts w:eastAsia="SimHei"/><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading3">
            <w:name w:val="heading 3"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:spacing w:before="180" w:after="120"/><w:outlineLvl w:val="2"/></w:pPr>
            <w:rPr><w:rFonts w:eastAsia="SimHei"/><w:b/><w:sz w:val="25"/><w:szCs w:val="25"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="FootnoteText">
            <w:name w:val="footnote text"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:spacing w:after="60" w:line="260" w:lineRule="auto"/></w:pPr>
            <w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr>
          </w:style>
          <w:style w:type="character" w:styleId="FootnoteReference">
            <w:name w:val="footnote reference"/>
            <w:rPr><w:vertAlign w:val="superscript"/></w:rPr>
          </w:style>
        </w:styles>
        """
    }

    private static func docxFootnotesXML(_ notes: [DocxFootnote]) -> String {
        var items = """
          <w:footnote w:type="separator" w:id="-1">
            <w:p><w:r><w:separator/></w:r></w:p>
          </w:footnote>
          <w:footnote w:type="continuationSeparator" w:id="0">
            <w:p><w:r><w:continuationSeparator/></w:r></w:p>
          </w:footnote>
        """
        for note in notes {
            items += """
              <w:footnote w:id="\(note.id)">
                <w:p>
                  <w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr>
                  <w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r>
                  <w:r><w:t xml:space="preserve"> \(xmlEscape(note.text))</w:t></w:r>
                </w:p>
              </w:footnote>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \(items)
        </w:footnotes>
        """
    }

    private static func docxHeadingParagraph(text: String, level: Int, resolveFootnote: (String) -> Int?) -> String {
        let styleID = level == 1 ? "Heading1" : (level == 2 ? "Heading2" : "Heading3")
        return "<w:p><w:pPr><w:pStyle w:val=\"\(styleID)\"/></w:pPr>\(docxInlineRuns(text, resolveFootnote: resolveFootnote))</w:p>"
    }

    private static func docxBodyParagraph(text: String, resolveFootnote: (String) -> Int?) -> String {
        "<w:p><w:pPr><w:ind w:firstLineChars=\"200\" w:firstLine=\"480\"/></w:pPr>\(docxInlineRuns(text, resolveFootnote: resolveFootnote))</w:p>"
    }

    private static func docxQuoteParagraph(text: String, resolveFootnote: (String) -> Int?) -> String {
        "<w:p><w:pPr><w:ind w:left=\"480\"/><w:pBdr><w:left w:val=\"single\" w:sz=\"12\" w:space=\"8\" w:color=\"B8B8B4\"/></w:pBdr></w:pPr>\(docxInlineRuns(text, resolveFootnote: resolveFootnote, italic: false, color: "424240"))</w:p>"
    }

    private static func docxListParagraph(marker: String, text: String, resolveFootnote: (String) -> Int?) -> String {
        "<w:p><w:pPr><w:ind w:left=\"420\" w:hanging=\"220\"/></w:pPr><w:r><w:t xml:space=\"preserve\">\(xmlEscape(marker))</w:t></w:r>\(docxInlineRuns(text, resolveFootnote: resolveFootnote))</w:p>"
    }

    private static func docxTable(headers: [String], rows: [[String]], resolveFootnote: (String) -> Int?) -> String {
        let colCount = max(headers.count, rows.map(\.count).max() ?? 1)
        guard colCount > 0 else { return "" }
        let cellW = max(1200, 9000 / colCount)
        var xml = """
        <w:tbl>
          <w:tblPr>
            <w:tblW w:w="9000" w:type="dxa"/>
            <w:tblBorders>
              <w:top w:val="single" w:sz="4" w:space="0" w:color="CCCCCC"/>
              <w:left w:val="single" w:sz="4" w:space="0" w:color="CCCCCC"/>
              <w:bottom w:val="single" w:sz="4" w:space="0" w:color="CCCCCC"/>
              <w:right w:val="single" w:sz="4" w:space="0" w:color="CCCCCC"/>
              <w:insideH w:val="single" w:sz="4" w:space="0" w:color="DDDDDD"/>
              <w:insideV w:val="single" w:sz="4" w:space="0" w:color="DDDDDD"/>
            </w:tblBorders>
          </w:tblPr>
        """
        func buildRow(_ cells: [String], isHeader: Bool) -> String {
            var r = "<w:tr>"
            for c in 0..<colCount {
                let text = c < cells.count ? cells[c] : ""
                let shade = isHeader ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F1\"/>" : ""
                r += "<w:tc><w:tcPr><w:tcW w:w=\"\(cellW)\" w:type=\"dxa\"/>\(shade)</w:tcPr><w:p><w:pPr><w:spacing w:after=\"60\" w:line=\"260\" w:lineRule=\"auto\"/></w:pPr>\(docxInlineRuns(text, resolveFootnote: resolveFootnote, bold: isHeader))</w:p></w:tc>"
            }
            r += "</w:tr>"
            return r
        }
        xml += buildRow(headers, isHeader: true)
        for row in rows { xml += buildRow(row, isHeader: false) }
        xml += "</w:tbl><w:p/>"
        return xml
    }

    private static func docxInlineRuns(_ text: String, resolveFootnote: (String) -> Int?, bold: Bool = false, italic: Bool = false, color: String? = nil) -> String {
        var xml = ""
        var i = text.startIndex
        var buf = ""

        func flush(_ isBold: Bool = bold, _ isItalic: Bool = italic) {
            guard !buf.isEmpty else { return }
            var rPr = ""
            if isBold { rPr += "<w:b/>" }
            if isItalic { rPr += "<w:i/>" }
            if let color { rPr += "<w:color w:val=\"\(color)\"/>" }
            let prTag = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
            xml += "<w:r>\(prTag)<w:t xml:space=\"preserve\">\(xmlEscape(buf))</w:t></w:r>"
            buf = ""
        }

        while i < text.endIndex {
            // Inline footnote reference: [^key]
            if text[i] == "[", let next = text.index(i, offsetBy: 1, limitedBy: text.endIndex), next < text.endIndex, text[next] == "^" {
                let afterCaret = text.index(after: next)
                if let closeBracket = text[afterCaret...].firstIndex(of: "]") {
                    let key = String(text[afterCaret..<closeBracket]).trimmingCharacters(in: .whitespaces)
                    if let fnID = resolveFootnote(key) {
                        flush()
                        xml += "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/><w:vertAlign w:val=\"superscript\"/></w:rPr><w:footnoteReference w:id=\"\(fnID)\"/></w:r>"
                        i = text.index(after: closeBracket)
                        continue
                    }
                }
            }
            // Bold **...**
            if text[i...].hasPrefix("**") {
                let afterStart = text.index(i, offsetBy: 2)
                if let closeRange = text[afterStart...].range(of: "**") {
                    flush()
                    let inner = String(text[afterStart..<closeRange.lowerBound])
                    xml += docxInlineRuns(inner, resolveFootnote: resolveFootnote, bold: true, italic: italic, color: color)
                    i = closeRange.upperBound
                    continue
                }
            }
            buf.append(text[i])
            i = text.index(after: i)
        }
        flush()
        return xml
    }

    private static func parseFootnoteDefinition(_ line: String) -> (key: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[^"),
              let closeRange = trimmed.range(of: "]:") else { return nil }
        let keyStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let key = String(trimmed[keyStart..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.count <= 24 else { return nil }
        let text = String(trimmed[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (key, text)
    }

    private static func parseNumberedListLine(_ trimmed: String) -> (marker: String, text: String)? {
        guard let dotIdx = trimmed.firstIndex(of: ".") else { return nil }
        let prefix = trimmed[..<dotIdx]
        guard !prefix.isEmpty, prefix.count <= 4, prefix.allSatisfy(\.isNumber) else { return nil }
        let afterDot = trimmed.index(after: dotIdx)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        let rest = String(trimmed[trimmed.index(after: afterDot)...]).trimmingCharacters(in: .whitespaces)
        return ("\(prefix).", rest)
    }

    private static func isMarkdownTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        let allowed = CharacterSet(charactersIn: "|-: \t")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - XLSX Compiler (Multi-Sheet OOXML with Shared Strings & Column Auto-Width)

    static func compileXLSX(_ spec: XlsxWorkbookSpec) throws -> XlsxCompiledResult {
        guard !spec.sheets.isEmpty else {
            throw DocumentStudioError.invalidSpecification("至少需要 1 张工作表才能生成 XLSX。")
        }

        var sharedStrings: [String] = []
        var stringIndexMap: [String: Int] = [:]

        func internString(_ s: String) -> Int {
            if let idx = stringIndexMap[s] { return idx }
            let idx = sharedStrings.count
            sharedStrings.append(s)
            stringIndexMap[s] = idx
            return idx
        }

        var entries: [SimpleZipWriter.Entry] = []
        var sheetOverrides = ""
        var workbookSheetsXML = ""
        var workbookRelsXML = ""
        var totalRows = 0

        var usedSheetNames = Set<String>()
        for (i, sheet) in spec.sheets.prefix(20).enumerated() {
            let sheetNum = i + 1
            let baseName = sanitizeExcelSheetName(sheet.name, fallback: "工作表\(sheetNum)")
            var safeSheetName = baseName
            var duplicate = 1
            while !usedSheetNames.insert(safeSheetName.lowercased()).inserted {
                duplicate += 1
                let suffix = " (\(duplicate))"
                safeSheetName = String(baseName.prefix(31 - suffix.count)) + suffix
            }
            sheetOverrides += "<Override PartName=\"/xl/worksheets/sheet\(sheetNum).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>\n"
            workbookSheetsXML += "<sheet name=\"\(xmlEscape(safeSheetName))\" sheetId=\"\(sheetNum)\" r:id=\"rId\(sheetNum)\"/>\n"
            workbookRelsXML += "<Relationship Id=\"rId\(sheetNum)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(sheetNum).xml\"/>\n"

            var allRows: [[String]] = []
            if !sheet.headers.isEmpty { allRows.append(sheet.headers) }
            allRows.append(contentsOf: sheet.rows)
            totalRows += allRows.count

            let maxCols = max(1, allRows.map(\.count).max() ?? 1)
            var colWidths = Array(repeating: 10.0, count: maxCols)
            for row in allRows {
                for (c, cell) in row.enumerated() where c < maxCols {
                    let displayWidth = cell.reduce(0.0) { acc, ch in
                        acc + (ch.isASCII ? 1.15 : 2.15)
                    }
                    colWidths[c] = min(48.0, max(colWidths[c], displayWidth + 3.0))
                }
            }

            var colsXML = "<cols>"
            for c in 0..<maxCols {
                colsXML += "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(String(format: "%.1f", colWidths[c]))\" customWidth=\"1\"/>"
            }
            colsXML += "</cols>"

            var sheetDataXML = "<sheetData>"
            for (rIdx, row) in allRows.enumerated() {
                let excelRow = rIdx + 1
                let isHeader = !sheet.headers.isEmpty && rIdx == 0
                sheetDataXML += "<row r=\"\(excelRow)\">"
                for (cIdx, val) in row.enumerated() {
                    let ref = excelColumnLetter(cIdx) + "\(excelRow)"
                    let styleIdx = isHeader ? 1 : 0
                    let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !isHeader, !trimmed.isEmpty, isPlainExcelNumber(trimmed) {
                        sheetDataXML += "<c r=\"\(ref)\" s=\"\(styleIdx)\"><v>\(trimmed)</v></c>"
                    } else {
                        let ssIdx = internString(val)
                        sheetDataXML += "<c r=\"\(ref)\" t=\"s\" s=\"\(styleIdx)\"><v>\(ssIdx)</v></c>"
                    }
                }
                sheetDataXML += "</row>"
            }
            sheetDataXML += "</sheetData>"

            let freezeXML = !sheet.headers.isEmpty
                ? "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
                : ""

            let sheetXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              \(freezeXML)
              \(colsXML)
              \(sheetDataXML)
            </worksheet>
            """
            entries.append(.init(path: "xl/worksheets/sheet\(sheetNum).xml", data: Data(sheetXML.utf8)))
        }

        let ssItems = sharedStrings.map { "<si><t xml:space=\"preserve\">\(xmlEscape($0))</t></si>" }.joined()
        let sharedStringsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(sharedStrings.count)" uniqueCount="\(sharedStrings.count)">\(ssItems)</sst>
        """

        let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="2">
            <font><sz val="11"/><name val="PingFang SC"/></font>
            <font><b/><sz val="11"/><name val="PingFang SC"/></font>
          </fonts>
          <fills count="3">
            <fill><patternFill patternType="none"/></fill>
            <fill><patternFill patternType="gray125"/></fill>
            <fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F1"/><bgColor indexed="64"/></patternFill></fill>
          </fills>
          <borders count="1">
            <border><left/><right/><top/><bottom/><diagonal/></border>
          </borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="2">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"><alignment wrapText="1" vertical="center"/></xf>
            <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0"><alignment wrapText="1" vertical="center"/></xf>
          </cellXfs>
        </styleSheet>
        """

        let styleRelID = "rId\(spec.sheets.prefix(20).count + 1)"
        let ssRelID = "rId\(spec.sheets.prefix(20).count + 2)"
        workbookRelsXML += "<Relationship Id=\"\(styleRelID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>\n"
        workbookRelsXML += "<Relationship Id=\"\(ssRelID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>\n"

        let workbookXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            \(workbookSheetsXML)
          </sheets>
        </workbook>
        """

        let workbookRelsDoc = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          \(workbookRelsXML)
        </Relationships>
        """

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
          <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
          \(sheetOverrides)
        </Types>
        """

        entries.insert(.init(path: "[Content_Types].xml", data: Data(contentTypes.utf8)), at: 0)
        entries.insert(.init(path: "_rels/.rels", data: Data(rootRels.utf8)), at: 1)
        entries.append(.init(path: "xl/workbook.xml", data: Data(workbookXML.utf8)))
        entries.append(.init(path: "xl/_rels/workbook.xml.rels", data: Data(workbookRelsDoc.utf8)))
        entries.append(.init(path: "xl/styles.xml", data: Data(stylesXML.utf8)))
        entries.append(.init(path: "xl/sharedStrings.xml", data: Data(sharedStringsXML.utf8)))

        let zipped = try SimpleZipWriter.archive(entries)
        return XlsxCompiledResult(data: zipped, sheetCount: min(spec.sheets.count, 20), rowCount: totalRows)
    }

    private static func sanitizeExcelSheetName(_ raw: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: ":\\/?*[]")
        let cleaned = raw.components(separatedBy: forbidden).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(31))
    }

    private static func excelColumnLetter(_ index: Int) -> String {
        var n = index + 1
        var out = ""
        while n > 0 {
            let rem = (n - 1) % 26
            out = String(UnicodeScalar(65 + rem)!) + out
            n = (n - 1) / 26
        }
        return out
    }

    private static func isPlainExcelNumber(_ s: String) -> Bool {
        // Avoid stripping leading zeros like "0012" or phone numbers
        if s.count > 1 && s.hasPrefix("0") && !s.hasPrefix("0.") { return false }
        return Double(s) != nil && !s.lowercased().contains("nan") && !s.lowercased().contains("inf")
    }

    // MARK: - Vector Chinese PDF Compiler (Cross-Platform CoreGraphics + CoreText)

    static func compilePDF(title: String, markdown: String) throws -> Data {
        let trimmed = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentStudioError.emptyContent }

        let attributed = buildPDFAttributedString(title: title, markdown: trimmed)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)

        var mediaBox = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4
        let marginX: CGFloat = 54
        let topMargin: CGFloat = 58
        let bottomMargin: CGFloat = 56
        let contentRect = CGRect(
            x: marginX,
            y: bottomMargin,
            width: mediaBox.width - marginX * 2,
            height: mediaBox.height - topMargin - bottomMargin
        )
        let contentPath = CGPath(rect: contentRect, transform: nil)

        // Pass 1: paginate deterministically so every page footer displays exact "第 N 页 / 共 M 页"
        let totalLength = attributed.length
        var pageRanges: [CFRange] = []
        var cursor = 0
        while cursor < totalLength && pageRanges.count < 200 {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: cursor, length: 0), contentPath, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            pageRanges.append(visible)
            cursor += visible.length
        }
        guard !pageRanges.isEmpty else {
            throw DocumentStudioError.encodingFailed("PDF 排版分页失败。")
        }

        // Pass 2: render pages into PDF data consumer
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocumentStudioError.encodingFailed("无法初始化 PDF 渲染上下文。")
        }

        let footerFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, 9.5, nil)
        let footerColor = CGColor(gray: 0.48, alpha: 1.0)
        let ruleColor = CGColor(gray: 0.86, alpha: 1.0)
        let totalPages = pageRanges.count

        for (index, range) in pageRanges.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity

            // Header hairline + document title on pages >= 2
            if index > 0 && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let headerAttrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): footerFont,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): footerColor
                ]
                let headerLine = CTLineCreateWithAttributedString(NSAttributedString(string: String(title.prefix(40)), attributes: headerAttrs))
                ctx.textPosition = CGPoint(x: marginX, y: mediaBox.height - 34)
                CTLineDraw(headerLine, ctx)
                ctx.setStrokeColor(ruleColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: marginX, y: mediaBox.height - 42))
                ctx.addLine(to: CGPoint(x: mediaBox.width - marginX, y: mediaBox.height - 42))
                ctx.strokePath()
            }

            let frame = CTFramesetterCreateFrame(framesetter, range, contentPath, nil)
            CTFrameDraw(frame, ctx)

            // Centered page number footer
            let footerText = "第 \(index + 1) 页 / 共 \(totalPages) 页"
            let footerAttrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): footerFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): footerColor
            ]
            let footerLine = CTLineCreateWithAttributedString(NSAttributedString(string: footerText, attributes: footerAttrs))
            let bounds = CTLineGetBoundsWithOptions(footerLine, [])
            ctx.textPosition = CGPoint(x: (mediaBox.width - bounds.width) / 2, y: 28)
            CTLineDraw(footerLine, ctx)

            ctx.endPDFPage()
        }
        ctx.closePDF()

        let result = pdfData as Data
        guard !result.isEmpty else { throw DocumentStudioError.encodingFailed("PDF 输出字节为空。") }
        return result
    }

    private static func buildPDFAttributedString(title: String, markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let inkColor = CGColor(gray: 0.10, alpha: 1.0)
        let mutedColor = CGColor(gray: 0.36, alpha: 1.0)

        let bodyFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, 11.5, nil)
        let boldFont = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 11.5, nil)
        let h1Font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 17.5, nil)
        let h2Font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 14.0, nil)
        let h3Font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 12.5, nil)

        func makeParagraphStyle(lineSpacing: CGFloat, spacingBefore: CGFloat, spacingAfter: CGFloat, firstLineIndent: CGFloat = 0) -> CTParagraphStyle {
            var ls = lineSpacing
            var sb = spacingBefore
            var sa = spacingAfter
            var fl = firstLineIndent
            return withUnsafePointer(to: &ls) { pLS in
                withUnsafePointer(to: &sb) { pSB in
                    withUnsafePointer(to: &sa) { pSA in
                        withUnsafePointer(to: &fl) { pFL in
                            let settings: [CTParagraphStyleSetting] = [
                                CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: pLS),
                                CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: MemoryLayout<CGFloat>.size, value: pSB),
                                CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: pSA),
                                CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: pFL)
                            ]
                            return CTParagraphStyleCreate(settings, settings.count)
                        }
                    }
                }
            }
        }

        let bodyPara = makeParagraphStyle(lineSpacing: 5.5, spacingBefore: 0, spacingAfter: 8)
        let h1Para = makeParagraphStyle(lineSpacing: 5.0, spacingBefore: 10, spacingAfter: 10)
        let h2Para = makeParagraphStyle(lineSpacing: 4.5, spacingBefore: 12, spacingAfter: 6)
        let h3Para = makeParagraphStyle(lineSpacing: 4.0, spacingBefore: 9, spacingAfter: 5)

        let lines = markdown.components(separatedBy: "\n")
        let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !firstLine.hasPrefix("#") {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): h1Font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): inkColor,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): h1Para
            ]
            result.append(NSAttributedString(string: title + "\n", attributes: attrs))
        }

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                let level = min(3, max(1, trimmed.prefix(while: { $0 == "#" }).count))
                let text = String(trimmed.drop(while: { $0 == "#" || $0 == " " }))
                let font = level == 1 ? h1Font : (level == 2 ? h2Font : h3Font)
                let style = level == 1 ? h1Para : (level == 2 ? h2Para : h3Para)
                let attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): inkColor,
                    NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style
                ]
                result.append(NSAttributedString(string: text + "\n", attributes: attrs))
            } else if trimmed.hasPrefix(">") {
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                let attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): bodyFont,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): mutedColor,
                    NSAttributedString.Key(kCTParagraphStyleAttributeName as String): makeParagraphStyle(lineSpacing: 5, spacingBefore: 2, spacingAfter: 8, firstLineIndent: 16)
                ]
                result.append(NSAttributedString(string: "｜ " + text + "\n", attributes: attrs))
            } else {
                // Clean simple inline bold markers while rendering body text
                let segments = splitInlineBold(trimmed)
                for seg in segments {
                    let attrs: [NSAttributedString.Key: Any] = [
                        NSAttributedString.Key(kCTFontAttributeName as String): seg.isBold ? boldFont : bodyFont,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): inkColor,
                        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): bodyPara
                    ]
                    result.append(NSAttributedString(string: seg.text, attributes: attrs))
                }
                result.append(NSAttributedString(string: "\n", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): bodyFont,
                    NSAttributedString.Key(kCTParagraphStyleAttributeName as String): bodyPara
                ]))
            }
        }
        return result
    }

    private static func splitInlineBold(_ text: String) -> [(text: String, isBold: Bool)] {
        var out: [(String, Bool)] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if let open = text[cursor...].range(of: "**") {
                if open.lowerBound > cursor {
                    out.append((String(text[cursor..<open.lowerBound]), false))
                }
                if let close = text[open.upperBound...].range(of: "**") {
                    out.append((String(text[open.upperBound..<close.lowerBound]), true))
                    cursor = close.upperBound
                } else {
                    out.append((String(text[open.lowerBound...]), false))
                    break
                }
            } else {
                out.append((String(text[cursor...]), false))
                break
            }
        }
        return out
    }
}
