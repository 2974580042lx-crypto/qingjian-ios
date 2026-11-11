import XCTest
import Compression
@testable import DeepSeekCore

final class BookTests: XCTestCase {
    private let body = String(repeating: "他推开门，看见院子里的桂花落了一地。", count: 5)

    func testHeadingsSplitChaptersAndVolumeLinesJoinTheNextTitle() {
        let text = "第一卷 风起\n第一章 雨夜\n\(body)\n第二章 来客\n\(body)\n第三回 别离\n\(body)"
        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.map(\.title), ["第一卷 风起 · 第一章 雨夜", "第二章 来客", "第三回 别离"])
        XCTAssertEqual(chapters[1].text, body)
    }

    func testTextWithoutHeadingsIsCutIntoParts() {
        let text = (0..<40).map { _ in String(repeating: "雨", count: 400) }.joined(separator: "\n")
        let chapters = ChapterSplitter.split(text)
        XCTAssertGreaterThan(chapters.count, 1)
        XCTAssertEqual(chapters.first?.title, "第 1 段")
        XCTAssertEqual(chapters.reduce(0) { $0 + $1.text.filter { $0 == "雨" }.count }, 16000)
    }

    func testSegmentsGroupChaptersAndAShortTailJoinsTheLastOne() {
        func chapters(_ sizes: [Int]) -> [BookChapter] { sizes.map { BookChapter(title: "章", text: String(repeating: "字", count: $0)) } }
        XCTAssertEqual(ChapterSplitter.segments(for: chapters([15000, 15000, 15000, 15000, 15000]), target: 40000),
                       [BookSegment(first: 0, last: 2), BookSegment(first: 3, last: 4)])
        XCTAssertEqual(ChapterSplitter.segments(for: chapters([40000, 5000]), target: 40000), [BookSegment(first: 0, last: 1)])
        XCTAssertEqual(ChapterSplitter.segments(for: chapters([3000]), target: 40000), [BookSegment(first: 0, last: 0)])
    }

    func testGBKTextDecodesAndIsNormalized() throws {
        let original = "林黛玉进贾府，见过了外祖母。"
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        let data = try XCTUnwrap(original.data(using: gb))
        XCTAssertNil(String(data: data, encoding: .utf8))
        XCTAssertEqual(BookText.decode(data), original)
        XCTAssertEqual(BookText.normalized("\u{3000}\u{3000}第一段\r\n\r\n\r\n第二段  "), "第一段\n\n第二段")
        XCTAssertEqual(BookText.title(fromFileName: "《红楼梦》(精校版).txt"), "红楼梦")
    }

    func testSegmentNotesKeepOnlyQuotesAndPassagesFoundInTheText() throws {
        let chapters = [BookChapter(title: "第一章", text: "宝玉笑道：“这个妹妹我曾见过的。”\n窗外的竹影在风里摇着，一阵一阵地扫过窗纸，屋里只点着一盏灯。")]
        let answer = """
        ```json
        {"plot":"宝玉初见黛玉。","characters":[{"name":"贾宝玉","aliases":["宝玉"],"notes":"初见黛玉便说似曾相识。","quotes":["这个妹妹我曾见过的。","我从来没说过这句话呢"]}],
         "scenes":[{"title":"初见","chapter":"第1章","summary":"两人初见。","characters":["贾宝玉"]}],"terms":[],
         "excerpts":["窗外的竹影在风里摇着，一阵一阵地扫过窗纸","这一句原文里没有出现过"]}
        ```
        """
        let note = try BookReading.parseSegment(answer, segment: BookSegment(first: 0, last: 0), chapters: chapters)
        XCTAssertEqual(note.plot, "宝玉初见黛玉。")
        XCTAssertEqual(note.characters.first?.quotes, ["这个妹妹我曾见过的。"])
        XCTAssertEqual(note.characters.first?.aliases, ["宝玉"])
        XCTAssertEqual(note.scenes.first?.chapter, 0)
        XCTAssertEqual(note.excerpts.count, 1)
        XCTAssertTrue(note.excerpts[0].hasPrefix("窗外的竹影"))
        XCTAssertThrowsError(try BookReading.parseSegment("{\"characters\":[]}", segment: BookSegment(first: 0, last: 0), chapters: chapters))
    }

    func testCharactersMergeAcrossSegmentsByAlias() {
        let first = SegmentNote(segment: BookSegment(first: 0, last: 1), plot: "甲", characters: [.init(name: "贾宝玉", aliases: ["宝玉"], notes: "一")])
        let second = SegmentNote(segment: BookSegment(first: 2, last: 3), plot: "乙", characters: [.init(name: "宝玉", aliases: ["宝二爷"], notes: "二")])
        let merged = BookReading.mergedCharacters([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "贾宝玉")
        XCTAssertEqual(Set(merged[0].aliases), ["宝玉", "宝二爷"])
        XCTAssertEqual(merged[0].notes.map { $0.text }, ["一", "二"])
    }

    func testPassagesStayBeforeTheChapterLimit() {
        let chapters = [BookChapter(title: "一", text: "潇湘馆里竹影摇曳，黛玉独自坐着。"),
                        BookChapter(title: "二", text: "大观园里，潇湘馆的竹子被雪压弯了。")]
        let paragraphs = BookPassages.paragraphs(of: chapters)
        let early = BookPassages.find(in: "我们去潇湘馆看看", vocabulary: ["潇湘馆", "黛玉", "大观园"], paragraphs: paragraphs,
                                      upTo: 0, excluding: [])
        XCTAssertEqual(early.terms, ["潇湘馆"])
        XCTAssertEqual(early.passages, ["潇湘馆里竹影摇曳，黛玉独自坐着。"])
        let all = BookPassages.find(in: "我们去潇湘馆看看", vocabulary: ["潇湘馆"], paragraphs: paragraphs, upTo: 1, excluding: [])
        XCTAssertEqual(all.passages.first, "大观园里，潇湘馆的竹子被雪压弯了。")
        XCTAssertTrue(BookPassages.find(in: "黛玉在吗", vocabulary: ["黛玉"], paragraphs: paragraphs, upTo: 1, excluding: ["黛玉"]).passages.isEmpty)
    }

    func testStoryPromptCarriesTheCharacterAndTheUsersRole() {
        var book = Book(title: "红楼梦", characterCount: 100, chapterTitles: ["一"], segments: [BookSegment(first: 0, last: 0)], notes: [nil])
        var profile = BookProfile()
        profile.characters = [BookCharacter(name: "林黛玉", identity: "贾母的外孙女"), BookCharacter(name: "贾宝玉", identity: "荣国府公子")]
        profile.style = BookStyle(description: "白话夹文言。", excerpts: ["原文片段"])
        book.profile = profile
        book.status = .ready
        let session = StorySession(bookID: book.id, bookTitle: book.title, character: "林黛玉", userRole: "贾宝玉")
        let prompt = StoryPrompt.compose(session, book: book)
        XCTAssertTrue(prompt.contains("你扮演林黛玉"))
        XCTAssertTrue(prompt.contains("【林黛玉】"))
        XCTAssertTrue(prompt.contains("【用户扮演的贾宝玉】"))
        XCTAssertTrue(prompt.contains("白话夹文言。"))
        XCTAssertFalse(prompt.contains("- 贾宝玉："), "The user's own character is not listed again among the others.")
        XCTAssertTrue(StoryPrompt.compose(session, book: nil).contains("已从书架移除"))
    }
    func testTimePointKeepsLaterStoryOutOfThePrompt() {
        var book = Book(title: "红楼梦", characterCount: 100, chapterTitles: ["一", "二", "三", "四"],
                        segments: [BookSegment(first: 0, last: 1), BookSegment(first: 2, last: 3)], notes: [nil, nil])
        var profile = BookProfile()
        var daiyu = BookCharacter(name: "林黛玉", identity: "贾母的外孙女")
        daiyu.arc = "LATER_ARC"
        daiyu.relationships = "LATER_RELATIONS"
        daiyu.quotes = [BookQuote(text: "EARLY_LINE", chapter: 0), BookQuote(text: "LATE_LINE", chapter: 3)]
        var baochai = BookCharacter(name: "薛宝钗", identity: "薛家小姐")
        baochai.firstChapter = 3
        profile.characters = [daiyu, baochai]
        profile.summary = "WHOLE_BOOK_SUMMARY"
        profile.terms = [BookTerm(term: "潇湘馆", note: "黛玉的住处", chapter: 2), BookTerm(term: "荣国府", note: "贾府", chapter: 0)]
        book.profile = profile
        book.status = .ready
        var session = StorySession(bookID: book.id, bookTitle: book.title, character: "林黛玉")
        session.chapter = 1
        session.briefing = "BRIEFING_TEXT"
        session.instruction = "MY_RULES"
        let prompt = StoryPrompt.compose(session, book: book)
        XCTAssertTrue(prompt.contains("BRIEFING_TEXT"))
        XCTAssertTrue(prompt.contains("EARLY_LINE"))
        for hidden in ["LATE_LINE", "LATER_ARC", "LATER_RELATIONS", "WHOLE_BOOK_SUMMARY", "薛宝钗"] {
            XCTAssertFalse(prompt.contains(hidden), hidden)
        }
        XCTAssertTrue(prompt.hasSuffix("MY_RULES"), "The player's own rules come last.")
        XCTAssertEqual(StoryPrompt.vocabulary(of: profile, upTo: 1).sorted(), ["林黛玉", "荣国府"].sorted())

        session.chapter = nil
        let whole = StoryPrompt.compose(session, book: book)
        XCTAssertTrue(whole.contains("LATER_ARC") && whole.contains("WHOLE_BOOK_SUMMARY") && whole.contains("薛宝钗"))
    }

    func testGuestsAndOwnCardsJoinThePrompt() {
        var home = Book(title: "红楼梦", characterCount: 1, chapterTitles: ["一"], segments: [BookSegment(first: 0, last: 0)], notes: [nil])
        var homeProfile = BookProfile()
        homeProfile.characters = [BookCharacter(name: "林黛玉", identity: "贾母的外孙女")]
        home.profile = homeProfile
        var away = Book(title: "三国演义", characterCount: 1, chapterTitles: ["一"], segments: [BookSegment(first: 0, last: 0)], notes: [nil])
        var awayProfile = BookProfile()
        awayProfile.characters = [BookCharacter(name: "诸葛亮", identity: "蜀汉丞相")]
        away.profile = awayProfile
        var session = StorySession(bookID: home.id, bookTitle: home.title, character: "林黛玉", userRole: "阿青")
        session.guests = [StoryGuest(bookID: away.id, bookTitle: away.title, character: "诸葛亮")]
        session.userCard = "江南来的绣娘，爱笑"
        let prompt = StoryPrompt.compose(session, book: home, guestBooks: [away])
        XCTAssertTrue(prompt.contains("你扮演林黛玉、诸葛亮"))
        XCTAssertTrue(prompt.contains("【客串人物：诸葛亮（来自《三国演义》）】"))
        XCTAssertTrue(prompt.contains("蜀汉丞相"))
        XCTAssertTrue(prompt.contains("【用户扮演的阿青】\n江南来的绣娘，爱笑"))
    }

    func testBriefingReadsOnlyUpToTheStartingChapter() {
        var book = Book(title: "书", characterCount: 1, chapterTitles: ["一", "二", "三", "四"],
                        segments: [BookSegment(first: 0, last: 1), BookSegment(first: 2, last: 3)], notes: [nil, nil])
        book.notes = [SegmentNote(segment: BookSegment(first: 0, last: 1), plot: "EARLY_PLOT"),
                      SegmentNote(segment: BookSegment(first: 2, last: 3), plot: "LATE_PLOT")]
        let request = BookReading.briefingRequest(book: book, chapter: 1, character: "甲", userRole: "")
        let text = request.messages.last?.content ?? ""
        XCTAssertTrue(text.contains("EARLY_PLOT"))
        XCTAssertFalse(text.contains("LATE_PLOT"))
    }
    func testCharacterPassagesAreSpeechByThatCharacterBeforeTheLimit() {
        let chapters = [
            BookChapter(title: "一", text: "黛玉冷笑道：“我说呢，亏了绊住，不然早就飞了来了。”众人听了都笑起来，屋里一时热闹得很。"),
            BookChapter(title: "二", text: "这一日天气晴好，园子里的花开得正盛，小丫头们在廊下说笑，风吹过竹梢沙沙地响。"),
            BookChapter(title: "三", text: "黛玉道：“你又来招我。”说着便把脸转了过去，半日不肯回头，只拿帕子拭着眼角。")]
        let paragraphs = BookPassages.paragraphs(of: chapters)
        let early = BookPassages.characterPassages(names: ["林黛玉", "黛玉"], paragraphs: paragraphs, upTo: 1)
        XCTAssertEqual(early.count, 1)
        XCTAssertTrue(early[0].hasPrefix("黛玉冷笑道"))
        XCTAssertEqual(BookPassages.characterPassages(names: ["黛玉"], paragraphs: paragraphs, upTo: 2).count, 2)
    }

    func testDeepReadsKeepTheCardAndPickVerbatimExcerpts() throws {
        let card = BookCharacter(name: "林黛玉", identity: "旧身份", speech: "旧说话方式")
        let answer = #"{"personality":"敏感多思，嘴上不饶人。","behavior":"受了委屈先刺人，再独自落泪。","taboos":"不会撒娇讨好。"}"#
        let next = try BookReading.parseCharacterDeepRead(answer, into: card)
        XCTAssertEqual(next.personality, "敏感多思，嘴上不饶人。")
        XCTAssertEqual(next.identity, "旧身份", "Fields the read leaves out stay as they were.")
        XCTAssertEqual(next.behavior, "受了委屈先刺人，再独自落泪。")
        XCTAssertNotNil(next.deepReadAt)
        XCTAssertThrowsError(try BookReading.parseCharacterDeepRead("{}", into: card))

        let samples = ["第一段原文。", "第二段原文。", "第三段原文。"]
        let style = try BookReading.parseStyleDeepRead(#"{"description":"短句白描。","signatures":["多用短句"],"avoid":["仿佛"],"best":[3,"1",9]}"#,
                                                       into: BookStyle(description: "旧", excerpts: ["旧片段"]), samples: samples)
        XCTAssertEqual(style.description, "短句白描。")
        XCTAssertEqual(style.excerpts, ["第三段原文。", "第一段原文。"])
        XCTAssertEqual(style.avoid, ["仿佛"])
    }

    func testPromptCarriesCorrectionsPassagesAndStyleRules() {
        var book = Book(title: "红楼梦", characterCount: 1, chapterTitles: ["一"], segments: [BookSegment(first: 0, last: 0)], notes: [nil])
        var profile = BookProfile()
        var daiyu = BookCharacter(name: "林黛玉", identity: "贾母的外孙女")
        daiyu.taboos = "不会撒娇讨好"
        daiyu.corrections = ["她不会直说喜欢"]
        profile.characters = [daiyu]
        profile.style = BookStyle(description: "白话夹文言。", excerpts: [], signatures: ["多用短句"], avoid: ["仿佛"])
        book.profile = profile
        var session = StorySession(bookID: book.id, bookTitle: book.title, character: "林黛玉")
        session.characterPassages = ["黛玉冷笑道：“我说呢。”"]
        let prompt = StoryPrompt.compose(session, book: book)
        for expected in ["绝不会说或做的事：不会撒娇讨好", "- 她不会直说喜欢", "【原著里的林黛玉】", "黛玉冷笑道", "- 多用短句", "- 仿佛"] {
            XCTAssertTrue(prompt.contains(expected), expected)
        }
    }
    func testPriceBandSaysWhenItEnds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let wednesday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10, minute: 30)))
        XCTAssertEqual(Pricing.statusLabel(at: wednesday), "高峰时段 · 到 12:00 结束")
        let lunch = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 5)))
        XCTAssertEqual(Pricing.statusLabel(at: lunch), "空闲时段 · 半价，到 14:00")
        let friday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 19)))
        XCTAssertEqual(Pricing.statusLabel(at: friday), "空闲时段 · 半价，到 周一 09:00")
    }

    func testBooksReadWithFlashUnlessSetToPro() {
        var book = Book(title: "书", characterCount: 1, chapterTitles: ["一"], segments: [BookSegment(first: 0, last: 0)], notes: [nil])
        let chapters = [BookChapter(title: "一", text: "正文")]
        XCTAssertEqual(BookReading.segmentRequest(book: book, segment: book.segments[0], chapters: chapters).model, DeepSeekModel.flash.rawValue)
        book.readingModel = .pro
        XCTAssertEqual(BookReading.segmentRequest(book: book, segment: book.segments[0], chapters: chapters).model, DeepSeekModel.pro.rawValue)
    }
    func testDialogueIsAttributedToTheSubjectOfTheLeadIn() {
        let chapters = [BookChapter(title: "一", text: [
            "黛玉冷笑道：“我说呢，亏了绊住，不然早就飞了来了。”",
            "宝玉见林黛玉进来，忙起身笑道：“好妹妹，你来了。”",
            "“你又来招我。”黛玉哭道。",
            "窗外下着雨，没有人说话。"].joined(separator: "\n"))]
        let names = ["林黛玉": "林黛玉", "黛玉": "林黛玉", "贾宝玉": "贾宝玉", "宝玉": "贾宝玉"]
        let lines = DialogueIndex.build(paragraphs: BookPassages.paragraphs(of: chapters), names: names)
        XCTAssertEqual(lines.map(\.speaker), ["林黛玉", "贾宝玉", "林黛玉"])
        XCTAssertEqual(lines[0].manner, "冷笑道")
        XCTAssertEqual(lines[0].mood, .cold)
        XCTAssertEqual(lines[1].text, "好妹妹，你来了。")
        XCTAssertEqual(lines[1].mood, .happy)
        XCTAssertEqual(lines[2].mood, .sad)
    }

    func testPickedLinesFitTheMomentAndStayBeforeTheTimePoint() {
        func line(_ text: String, _ mood: DialogueMood, chapter: Int, context: String = "") -> DialogueLine {
            DialogueLine(speaker: "林黛玉", manner: "道", mood: mood, text: text, context: context, chapter: chapter)
        }
        let lines = [line("早一", .calm, chapter: 0), line("气话", .angry, chapter: 1), line("对宝玉说", .calm, chapter: 1, context: "宝玉在旁"),
                     line("以后的话", .angry, chapter: 9), line("伤心话", .sad, chapter: 2)]
        let picked = DialogueIndex.pick(lines, speaker: "林黛玉", recent: "你怎么又惹我生气了", partners: ["宝玉"], upTo: 2, limit: 2)
        XCTAssertEqual(picked.map(\.text), ["对宝玉说", "气话"])
        XCTAssertFalse(DialogueIndex.pick(lines, speaker: "林黛玉", recent: "", partners: [], upTo: 2).contains { $0.text == "以后的话" })
        XCTAssertNotNil(DialogueIndex.note(picked, speaker: "林黛玉"))
    }
    func testCanonMarkIsHiddenAndSkippingPassesStretchesWithoutYou() {
        XCTAssertEqual(CanonPlan.strip("他转身走了。\n〔本段完〕").text, "他转身走了。")
        XCTAssertTrue(CanonPlan.strip("他转身走了。【本段完】").finished)
        XCTAssertFalse(CanonPlan.strip("他转身走了。").finished)

        var book = Book(title: "书", characterCount: 1, chapterTitles: (1...8).map { "第\($0)章" },
                        segments: [BookSegment(first: 0, last: 1), BookSegment(first: 2, last: 3),
                                   BookSegment(first: 4, last: 5), BookSegment(first: 6, last: 7)], notes: [nil, nil, nil, nil])
        book.notes = [SegmentNote(segment: BookSegment(first: 0, last: 1), plot: "宝玉和黛玉初见。", characters: [.init(name: "贾宝玉", notes: "初见")]),
                      SegmentNote(segment: BookSegment(first: 2, last: 3), plot: "凤姐理家。", characters: [.init(name: "王熙凤", notes: "理家")]),
                      SegmentNote(segment: BookSegment(first: 4, last: 5), plot: "贾琏外出。", characters: [.init(name: "贾琏", notes: "外出")]),
                      SegmentNote(segment: BookSegment(first: 6, last: 7), plot: "宝玉挨打。", characters: [.init(name: "贾宝玉", notes: "挨打")])]
        let skipped = CanonPlan.advance(from: 0, book: book, userNames: ["贾宝玉", "宝玉"], mode: .skip)
        XCTAssertEqual(skipped.next, 3)
        XCTAssertTrue(skipped.bridge?.contains("凤姐理家") == true && skipped.bridge?.contains("贾琏外出") == true)
        let drawnIn = CanonPlan.advance(from: 0, book: book, userNames: ["贾宝玉"], mode: .involve)
        XCTAssertEqual(drawnIn.next, 1)
        XCTAssertNil(drawnIn.bridge)
        XCTAssertEqual(CanonPlan.segment(containing: 5, in: book), 2)

        var session = StorySession(bookID: book.id, bookTitle: book.title, character: "林黛玉", userRole: "贾宝玉")
        session.canon = .involve
        session.canonSegment = 1
        session.startChapter = 0
        let section = CanonPlan.section(session, book: book) ?? ""
        XCTAssertTrue(section.contains("凤姐理家") && section.contains("贾琏外出") && section.contains(CanonPlan.marker))
        XCTAssertFalse(section.contains("宝玉挨打"), "Only this stretch and a glimpse of the next.")
        session.canonSegment = 4
        XCTAssertTrue(CanonPlan.section(session, book: book)?.contains("走完") == true)
        session.canon = nil
        XCTAssertNil(CanonPlan.section(session, book: book))
    }
    // A minimal ZIP, as EPUB tools write them: local headers, central directory, end record.
    private func zip(_ files: [(name: String, text: String, deflate: Bool)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }
        var body: [UInt8] = []
        var central: [UInt8] = []
        for file in files {
            let raw = [UInt8](file.text.utf8)
            var stored = raw
            if file.deflate {
                let capacity = raw.count + 1024
                var out = [UInt8](repeating: 0, count: capacity)
                let n = compression_encode_buffer(&out, capacity, raw, raw.count, nil, COMPRESSION_ZLIB)
                stored = Array(out.prefix(n))
            }
            let name = [UInt8](file.name.utf8)
            let method = file.deflate ? 8 : 0
            let offset = body.count
            body.append(contentsOf: le32(0x04034B50))
            body.append(contentsOf: le16(20)); body.append(contentsOf: le16(0x800)); body.append(contentsOf: le16(method))
            body.append(contentsOf: le32(0)); body.append(contentsOf: le32(0))
            body.append(contentsOf: le32(stored.count)); body.append(contentsOf: le32(raw.count))
            body.append(contentsOf: le16(name.count)); body.append(contentsOf: le16(0))
            body.append(contentsOf: name); body.append(contentsOf: stored)
            central.append(contentsOf: le32(0x02014B50))
            central.append(contentsOf: le16(20)); central.append(contentsOf: le16(20)); central.append(contentsOf: le16(0x800))
            central.append(contentsOf: le16(method)); central.append(contentsOf: le32(0)); central.append(contentsOf: le32(0))
            central.append(contentsOf: le32(stored.count)); central.append(contentsOf: le32(raw.count))
            central.append(contentsOf: le16(name.count)); central.append(contentsOf: le16(0)); central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0)); central.append(contentsOf: le16(0)); central.append(contentsOf: le32(0))
            central.append(contentsOf: le32(offset)); central.append(contentsOf: name)
        }
        var end: [UInt8] = le32(0x06054B50)
        end.append(contentsOf: le16(0)); end.append(contentsOf: le16(0))
        end.append(contentsOf: le16(files.count)); end.append(contentsOf: le16(files.count))
        end.append(contentsOf: le32(central.count)); end.append(contentsOf: le32(body.count)); end.append(contentsOf: le16(0))
        return Data(body + central + end)
    }

    func testEpubPagesBecomeChaptersInSpineOrder() throws {
        let long = String(repeating: "雨一直下，院子里的灯笼在风里摇晃，没有人说话。", count: 20)
        let container = #"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        let opf = """
        <package><metadata><dc:title>测试之书</dc:title></metadata><manifest>
        <item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="Text/c2.xhtml" media-type="application/xhtml+xml"/>
        <item id="c1" href="Text/c1.xhtml" media-type="application/xhtml+xml"/>
        <item id="css" href="Styles/a.css" media-type="text/css"/>
        </manifest><spine><itemref idref="cover"/><itemref idref="c1"/><itemref idref="c2"/></spine></package>
        """
        let page = { (heading: String, text: String) in
            "<html><head><title>页</title><style>p{}</style></head><body><h2>\(heading)</h2><p>\(text)</p><p>第&#x4E00;段&nbsp;完。</p></body></html>"
        }
        let data = zip([("mimetype", "application/epub+zip", false), ("META-INF/container.xml", container, true),
                        ("OEBPS/content.opf", opf, true), ("OEBPS/Text/cover.xhtml", "<html><body><p>封面</p></body></html>", false),
                        ("OEBPS/Text/c1.xhtml", page("第一章 雨夜", long), true), ("OEBPS/Text/c2.xhtml", page("第二章 来客", long), true)])
        let book = try EpubBook.pages(from: data)
        XCTAssertEqual(book.title, "测试之书")
        XCTAssertEqual(book.pages.count, 3)
        XCTAssertTrue(book.pages[1].text.hasPrefix("第一章 雨夜"))
        XCTAssertTrue(book.pages[1].text.contains("第一段 完。"))
        let chapters = EpubBook.chapters(from: book.pages)
        XCTAssertEqual(chapters.map(\.title), ["第一章 雨夜", "第二章 来客"])
        let prepared = try BookImport.prepare(data, fileName: "下载.epub")
        XCTAssertEqual(prepared.title, "测试之书")
        XCTAssertEqual(prepared.chapters.count, 2)
    }
    func testInnerThoughtsAskAboutOneAnswerAndStopThere() throws {
        let question = ChatMessage(role: .user, content: "你还生我的气吗？")
        let answer = ChatMessage(role: .assistant, content: "谁稀罕生你的气。")
        let later = ChatMessage(role: .assistant, content: "LATER_ANSWER")
        let request = try InnerThoughts.request(settings: AppSettings(), systemPrompt: "STORY_PROMPT",
                                                messages: [question, answer, ChatMessage(role: .user, content: "嗯"), later],
                                                answerID: answer.id, character: "林黛玉")
        XCTAssertTrue(request.messages.first?.content.hasPrefix("STORY_PROMPT\n\n") == true)
        XCTAssertTrue(request.messages.first?.content.contains("本次独立心声补写") == true)
        XCTAssertFalse(request.messages.contains { $0.content == "LATER_ANSWER" })
        XCTAssertTrue(request.messages.last?.content.contains("林黛玉") == true)
        XCTAssertEqual(request.messages[request.messages.count - 2].content, "谁稀罕生你的气。")
        XCTAssertThrowsError(try InnerThoughts.request(settings: AppSettings(), systemPrompt: "", messages: [question],
                                                       answerID: question.id, character: "林黛玉"))
    }
}
