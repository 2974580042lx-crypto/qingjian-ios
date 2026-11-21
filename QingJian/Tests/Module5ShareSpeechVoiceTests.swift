import XCTest
import Foundation
@testable import DeepSeekCore

final class Module5ShareSpeechVoiceTests: XCTestCase {

    func testShareIntakeURLParserClassifiesFilesImagesBackupsAndDeepLinks() throws {
        let backupURL = URL(fileURLWithPath: "/tmp/Sermo-2026-11-21.sermobackup")
        XCTAssertEqual(ShareIntakeURLParser.parse(backupURL), .backup(backupURL))

        let pdfURL = URL(fileURLWithPath: "/tmp/名公书判清明集.pdf")
        if case .intake(let item) = ShareIntakeURLParser.parse(pdfURL) {
            XCTAssertEqual(item.kind, .file)
            XCTAssertEqual(item.title, "名公书判清明集.pdf")
            XCTAssertEqual(item.localFileURL?.path, "/tmp/名公书判清明集.pdf")
        } else {
            XCTFail("Expected file intake")
        }

        let photoURL = URL(fileURLWithPath: "/tmp/IMG_1024.HEIC")
        if case .intake(let item) = ShareIntakeURLParser.parse(photoURL) {
            XCTAssertEqual(item.kind, .image)
            XCTAssertEqual(item.title, "IMG_1024.HEIC")
        } else {
            XCTFail("Expected image intake")
        }

        let webDeepLink = try XCTUnwrap(URL(string: "sermo://inbox?url=https%3A%2F%2Fexample.com%2Farticle&title=%E5%AE%8B%E4%BB%A3%E7%BA%A2%E7%99%BD%E5%A5%91&project=%E6%AF%95%E4%B8%9A%E8%AE%BA%E6%96%87"))
        if case .intake(let item) = ShareIntakeURLParser.parse(webDeepLink) {
            XCTAssertEqual(item.kind, .webLink)
            XCTAssertEqual(item.title, "宋代红白契")
            XCTAssertEqual(item.urlString, "https://example.com/article")
            XCTAssertEqual(item.preferredProjectName, "毕业论文")
            XCTAssertTrue(item.composerPrefillText().contains("https://example.com/article"))
            XCTAssertEqual(item.libraryTextPayload()?.name, "宋代红白契")
        } else {
            XCTFail("Expected webLink intake")
        }

        let textDeepLink = try XCTUnwrap(URL(string: "sermo://share?text=%E5%85%88%E5%B0%BD%E4%BA%B2%E9%82%BB%E8%80%83%E8%BE%A8&title=%E6%91%98%E5%BD%95"))
        if case .intake(let item) = ShareIntakeURLParser.parse(textDeepLink) {
            XCTAssertEqual(item.kind, .text)
            XCTAssertEqual(item.title, "摘录")
            XCTAssertEqual(item.bodyText, "先尽亲邻考辨")
            XCTAssertTrue(item.composerPrefillText().contains("先尽亲邻考辨"))
        } else {
            XCTFail("Expected text intake")
        }

        let ignored = try XCTUnwrap(URL(string: "https://example.com/not-sermo"))
        XCTAssertEqual(ShareIntakeURLParser.parse(ignored), .ignored)
    }

    func testShareInboxQueuePersistsAndDrainsCleanly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sermo-inbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let queue = ShareInboxQueue(rootDirectory: dir)
        XCTAssertEqual(queue.peekCount(), 0)

        let item1 = ShareIntakeItem(kind: .webLink, title: "Safari 网页", urlString: "https://apple.com")
        let item2 = ShareIntakeItem(kind: .text, title: "摘抄", bodyText: "唐代两税法以资产为宗")
        try queue.enqueue(item1)
        try queue.enqueue(item2)
        XCTAssertEqual(queue.peekCount(), 2)

        let drained = queue.drainPending()
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(drained[0].title, "Safari 网页")
        XCTAssertEqual(drained[1].bodyText, "唐代两税法以资产为宗")
        XCTAssertEqual(queue.peekCount(), 0)
        XCTAssertTrue(queue.drainPending().isEmpty)
    }

    func testSpeechRoutingAndMarkdownTextCleaner() {
        XCTAssertEqual(SpeechRouting.resolveBackend(preference: .auto, hasOpenAIKey: false), .systemOnly)
        XCTAssertEqual(SpeechRouting.resolveBackend(preference: .auto, hasOpenAIKey: true), .openAIWithSystemFallback)
        XCTAssertEqual(SpeechRouting.resolveBackend(preference: .system, hasOpenAIKey: true), .systemOnly)
        XCTAssertEqual(SpeechRouting.resolveBackend(preference: .openAI, hasOpenAIKey: false), .missingOpenAIKey)
        XCTAssertEqual(SpeechRouting.resolveBackend(preference: .openAI, hasOpenAIKey: true), .openAIOnly)

        let rawMarkdown = """
        ### 一、两税法的核心内容

        **两税法**由杨炎提出[^1]，详见[唐书食货志](https://example.com)。

        ```swift
        let x = 1
        ```

        > 户无主客，以见居为簿。
        """
        let cleaned = SpeechTextCleaner.cleanForSpeech(rawMarkdown)
        XCTAssertFalse(cleaned.contains("###"))
        XCTAssertFalse(cleaned.contains("**"))
        XCTAssertFalse(cleaned.contains("[^1]"))
        XCTAssertFalse(cleaned.contains("https://example.com"))
        XCTAssertTrue(cleaned.contains("一、两税法的核心内容"))
        XCTAssertTrue(cleaned.contains("唐书食货志"))
        XCTAssertTrue(cleaned.contains("（此处为代码片段）"))
        XCTAssertTrue(cleaned.contains("户无主客，以见居为簿。"))
    }

    func testSpeechAudioSessionGuardPreventsDuckOthersLeakAcrossRapidStartStop() {
        var guardState = SpeechAudioSessionGuard()
        let gen1 = guardState.beginPlayback()
        XCTAssertTrue(guardState.isSessionActive)

        // Rapid restart before gen1 callback arrives
        let gen2 = guardState.beginPlayback()
        XCTAssertNotEqual(gen1, gen2)
        XCTAssertTrue(guardState.isSessionActive)

        // Stale gen1 finish callback MUST NOT deactivate the live gen2 session
        XCTAssertFalse(guardState.endPlayback(generation: gen1))
        XCTAssertTrue(guardState.isSessionActive)

        // Active gen2 finish MUST deactivate audio session (restoring background music volume)
        XCTAssertTrue(guardState.endPlayback(generation: gen2))
        XCTAssertFalse(guardState.isSessionActive)

        // Repeated stop is idempotent and returns false
        XCTAssertFalse(guardState.endPlayback(generation: nil))
    }

    func testVoiceInputAndOralDrillPromptBuilder() {
        var historyProject = ChatProject(name: "313 历史考研")
        historyProject.studySubject = .history
        XCTAssertEqual(OralDrillPromptBuilder.defaultMode(for: historyProject), .oralDrill)
        XCTAssertEqual(OralDrillPromptBuilder.defaultMode(for: ChatProject(name: "日常聊天")), .dictation)

        XCTAssertEqual(
            OralDrillPromptBuilder.mergeIntoDraft(existing: "帮我总结一下", spoken: "王安石变法的主要措施"),
            "帮我总结一下，王安石变法的主要措施"
        )
        XCTAssertEqual(
            OralDrillPromptBuilder.mergeIntoDraft(existing: "帮我总结一下。", spoken: "重点讲青苗法"),
            "帮我总结一下。重点讲青苗法"
        )

        let drillPrompt = OralDrillPromptBuilder.buildOralDrillSubmission(
            spoken: "青苗法是在青黄不接时由官府向农民放贷，秋收后加息二分归还。",
            project: historyProject
        )
        XCTAssertTrue(drillPrompt.contains("【口述抽背作答】"))
        XCTAssertTrue(drillPrompt.contains("313 历史学考研标准采分点"))
        XCTAssertTrue(drillPrompt.contains("青苗法"))

        XCTAssertFalse(VoiceAuthorizationState.microphoneDenied.isReady)
        XCTAssertTrue(VoiceAuthorizationState.microphoneDenied.userMessage?.contains("麦克风") == true)
        XCTAssertTrue(VoiceAuthorizationState.speechDenied.userMessage?.contains("语音识别") == true)
        XCTAssertTrue(VoiceAuthorizationState.authorized.isReady)
    }
}
