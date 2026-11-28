import XCTest
@testable import DeepSeekCore

final class UniversalFileImportTests: XCTestCase {

    // MARK: - Synthetic ZIP Builder (STORE method 0)

    private func makeZip(_ files: [(String, Data)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        func appendU16(_ d: inout Data, _ v: UInt16) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
        }
        func appendU32(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 24) & 0xFF))
        }

        for (name, body) in files {
            let nameData = Data(name.utf8)
            let localOffset = UInt32(archive.count)

            // Local file header
            appendU32(&archive, 0x04034B50)
            appendU16(&archive, 20) // version needed
            appendU16(&archive, 0x0800) // UTF-8 flag
            appendU16(&archive, 0) // method 0 = store
            appendU16(&archive, 0) // mod time
            appendU16(&archive, 0) // mod date
            appendU32(&archive, 0) // crc32 (unused by reader)
            appendU32(&archive, UInt32(body.count))
            appendU32(&archive, UInt32(body.count))
            appendU16(&archive, UInt16(nameData.count))
            appendU16(&archive, 0) // extra len
            archive.append(nameData)
            archive.append(body)

            // Central directory header
            appendU32(&centralDirectory, 0x02014B50)
            appendU16(&centralDirectory, 20) // version made by
            appendU16(&centralDirectory, 20) // version needed
            appendU16(&centralDirectory, 0x0800) // UTF-8
            appendU16(&centralDirectory, 0) // store
            appendU16(&centralDirectory, 0)
            appendU16(&centralDirectory, 0)
            appendU32(&centralDirectory, 0)
            appendU32(&centralDirectory, UInt32(body.count))
            appendU32(&centralDirectory, UInt32(body.count))
            appendU16(&centralDirectory, UInt16(nameData.count))
            appendU16(&centralDirectory, 0)
            appendU16(&centralDirectory, 0)
            appendU16(&centralDirectory, 0)
            appendU16(&centralDirectory, 0)
            appendU32(&centralDirectory, 0)
            appendU32(&centralDirectory, localOffset)
            centralDirectory.append(nameData)
        }

        let cdOffset = UInt32(archive.count)
        let cdSize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)

        // EOCD
        appendU32(&archive, 0x06054B50)
        appendU16(&archive, 0)
        appendU16(&archive, 0)
        appendU16(&archive, UInt16(files.count))
        appendU16(&archive, UInt16(files.count))
        appendU32(&archive, cdSize)
        appendU32(&archive, cdOffset)
        appendU16(&archive, 0)
        return archive
    }

    private func makeSyntheticMachO64(cryptID: UInt32, dylibPath: String) -> Data {
        var dylibData = Data(dylibPath.utf8)
        dylibData.append(0)
        while (24 + dylibData.count) % 8 != 0 { dylibData.append(0) }
        let dylibCmdSize = UInt32(24 + dylibData.count)
        let encCmdSize: UInt32 = 24
        let sizeofcmds = encCmdSize + dylibCmdSize

        var data = Data()
        func u32(_ v: UInt32) {
            data.append(UInt8(v & 0xFF))
            data.append(UInt8((v >> 8) & 0xFF))
            data.append(UInt8((v >> 16) & 0xFF))
            data.append(UInt8((v >> 24) & 0xFF))
        }
        // mach_header_64 (32 bytes)
        u32(0xFEEDFACF) // magic
        u32(0x0100000C) // CPU_TYPE_ARM64
        u32(0)          // cpusubtype
        u32(2)          // MH_EXECUTE
        u32(2)          // ncmds
        u32(sizeofcmds) // sizeofcmds
        u32(0)          // flags
        u32(0)          // reserved

        // LC_ENCRYPTION_INFO_64 (0x2C, 24 bytes)
        u32(0x2C)
        u32(encCmdSize)
        u32(0) // cryptoff
        u32(0) // cryptsize
        u32(cryptID)
        u32(0) // pad

        // LC_LOAD_DYLIB (0x0C)
        u32(0x0C)
        u32(dylibCmdSize)
        u32(24) // name offset
        u32(0)  // timestamp
        u32(0)  // current version
        u32(0)  // compat version
        data.append(dylibData)
        return data
    }

    // MARK: - Tests

    func testStreamZipReaderReadsStoredEntriesAndRejectsInvalidData() throws {
        let zip = makeZip([("hello.txt", Data("world".utf8)), ("sub/a.swift", Data("let x = 1".utf8))])
        let reader = try StreamZipReader(data: zip)
        XCTAssertEqual(reader.entries.count, 2)
        let entry = try XCTUnwrap(reader.entry(named: "SUB/A.SWIFT"))
        let content = try reader.readEntry(entry)
        XCTAssertEqual(String(data: content, encoding: .utf8), "let x = 1")

        XCTAssertThrowsError(try StreamZipReader(data: Data("not a zip".utf8)))
    }

    func testZipProjectExtractorFiltersIgnoredDirsAndRespectsBudget() throws {
        let zip = makeZip([
            (".git/config", Data("secret".utf8)),
            ("node_modules/pkg/index.js", Data("ignored".utf8)),
            ("logo.png", Data([0x89, 0x50, 0x4E, 0x47])),
            ("README.md", Data("# My Project".utf8)),
            ("Sources/App.swift", Data(String(repeating: "let a = 1\n", count: 500).utf8))
        ])

        let doc = try ZipProjectExtractor.extract(data: zip, fileName: "proj.zip", maxCharacters: 900)
        XCTAssertFalse(doc.text.contains("secret"))
        XCTAssertFalse(doc.text.contains("node_modules/pkg/index.js"))
        XCTAssertTrue(doc.text.contains("README.md"))
        XCTAssertTrue(doc.text.contains("未展开文件清单"))
    }

    func testOfficeExtractorsAndBinaryPlist() throws {
        let docxZip = makeZip([
            ("word/document.xml", Data("<w:document><w:body><w:p><w:r><w:t>Hello Word</w:t></w:r></w:p></w:body></w:document>".utf8))
        ])
        XCTAssertEqual(try OfficeAndDocumentExtractor.extractDOCX(docxZip), "Hello Word")

        let xlsxZip = makeZip([
            ("xl/sharedStrings.xml", Data("<sst><si><t>Name</t></si><si><t>Score</t></si></sst>".utf8)),
            ("xl/workbook.xml", Data("<workbook><sheets><sheet name=\"Grades\"/></sheets></workbook>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet><sheetData><row><c t=\"s\"><v>0</v></c><c t=\"s\"><v>1</v></c></row></sheetData></worksheet>".utf8))
        ])
        let xlsxText = try OfficeAndDocumentExtractor.extractXLSX(xlsxZip)
        XCTAssertTrue(xlsxText.contains("## Grades"))
        XCTAssertTrue(xlsxText.contains("Name\tScore"))

        let pptxZip = makeZip([
            ("ppt/slides/slide1.xml", Data("<p:sld><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Slide Title</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>".utf8))
        ])
        let pptxText = try OfficeAndDocumentExtractor.extractPPTX(pptxZip)
        XCTAssertTrue(pptxText.contains("Slide Title"))

        let bplist = try PropertyListSerialization.data(fromPropertyList: ["Key": "Value"], format: .binary, options: 0)
        let xml = try OfficeAndDocumentExtractor.decodeBinaryPlist(bplist)
        XCTAssertTrue(xml.contains("<key>Key</key>"))
    }

    func testPendingDocumentCodecRoundTripAndURLRouting() {
        let doc = PendingDocument(name: "Report", fileExtension: "md", text: "Line 1\n[[SERMO_FILE_END]]\nLine 2")
        let encoded = PendingDocumentCodec.encode(userText: "Please review", documents: [doc])
        let decoded = PendingDocumentCodec.decode(encoded)

        XCTAssertEqual(decoded.userText, "Please review")
        XCTAssertEqual(decoded.attachments.count, 1)
        XCTAssertEqual(decoded.attachments[0].name, "Report")
        XCTAssertEqual(decoded.attachments[0].fileExtension, "md")
        XCTAssertEqual(decoded.attachments[0].text, doc.text)

        XCTAssertEqual(IncomingURLRoute.classify(URL(fileURLWithPath: "/tmp/a.sermobackup")), .backup)
        XCTAssertEqual(IncomingURLRoute.classify(URL(fileURLWithPath: "/tmp/a.json")), .chatDocument)
        XCTAssertEqual(IncomingURLRoute.classify(URL(fileURLWithPath: "/tmp/a.ipa")), .chatDocument)
    }

    func testProviderCapabilitiesSyntaxAndMath() {
        XCTAssertTrue(ProviderCapabilities.forProvider(.deepSeek).supportsWebSearch)
        XCTAssertFalse(ProviderCapabilities.forProvider(.colab).supportsWebSearch)

        let tokens = CodeSyntaxTokenizer.tokenize("let x = 42 // hi", language: "swift")
        XCTAssertTrue(tokens.contains(where: { $0.kind == .keyword && $0.text == "let" }))
        XCTAssertTrue(tokens.contains(where: { $0.kind == .numberLiteral && $0.text == "42" }))
        XCTAssertTrue(tokens.contains(where: { $0.kind == .comment && $0.text == "// hi" }))

        let math = MathFormatter.format("\\frac{a^2}{b_1} \\approx \\pi")
        XCTAssertEqual(math, "(a²)/(b₁) ≈ π")

        let blocks = MarkdownBlock.parse("Intro\n\n$$\nE = mc^2\n$$\n\nOutro")
        XCTAssertEqual(blocks, [
            .paragraph("Intro", marks: 0),
            .math("E = mc^2"),
            .paragraph("Outro", marks: 0)
        ])
    }

    func testCompatibleEndpointPresetsAndValidation() throws {
        var cfg = CompatibleEndpointConfig()
        XCTAssertEqual(cfg.activePreset, .openAI)
        XCTAssertEqual(try cfg.validatedURL().absoluteString, "https://api.openai.com/v1")

        cfg.set(CompatiblePresetConfig(baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.5-flash"), for: .gemini)
        XCTAssertEqual(try cfg.validatedURL().absoluteString, "https://generativelanguage.googleapis.com/v1beta/openai")

        cfg.set(CompatiblePresetConfig(baseURL: "http://192.168.1.50:11434/v1", model: "qwen2.5:14b"), for: .local)
        XCTAssertEqual(try cfg.validatedURL().absoluteString, "http://192.168.1.50:11434/v1")

        cfg.set(CompatiblePresetConfig(baseURL: "http://api.example.com/v1", model: "test"), for: .custom)
        XCTAssertThrowsError(try cfg.validatedURL())
    }
}
