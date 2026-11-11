import XCTest

final class NavigationUITests: XCTestCase {
    @MainActor func testFontChangeKeepsSettingsAndUnsavedPrompt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-settings", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8))
        let template = app.buttons["学习讲解"]
        for _ in 0..<15 where !template.isHittable { app.swipeUp() }
        XCTAssertTrue(template.isHittable)
        template.tap() // Changes the draft, without tapping Save.
        let editor = app.textViews["system-prompt-editor"]
        let draft = try XCTUnwrap(editor.value as? String)
        XCTAssertFalse(draft.isEmpty)
        let picker = app.descendants(matching: .any).matching(identifier: "font-choice").firstMatch
        for _ in 0..<8 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.isHittable)
        let original: String = try XCTUnwrap(picker.value as? String,
                                            "The font picker must expose its actual selected font.")
        let choices: [String] = ["内置宋体", "系统字体", "自定义字体"]
        guard choices.contains(original) else {
            XCTFail("The font picker reported an unknown selection: \(original)")
            return
        }
        let target = original.contains("系统字体") ? "内置宋体" : "系统字体"
        picker.tap()
        app.buttons[target].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].exists, "Font changes must preserve the settings sheet.")
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.value as? String == target
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, "The test must actually change the font.")
        for _ in 0..<10 where !editor.isHittable { app.swipeDown() }
        XCTAssertEqual(editor.value as? String, draft, "Changing a font must not discard the unsaved prompt.")
        capture(app, name: "font-change-keeps-settings-draft")
        // Keep the existing screenshot tests' appearance independent of this test.
        for _ in 0..<8 where !picker.isHittable { app.swipeUp() }
        picker.tap()
        app.buttons[original].firstMatch.tap()
    }

    @MainActor func testSuggestedReplyIsEditableAndDoesNotSendUntilRequested() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-reply-suggestions", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let choice = app.buttons["reply-suggestion-0"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        for _ in 0..<4 where !choice.isHittable { app.scrollViews["chat-scroll"].swipeUp() }
        XCTAssertTrue(choice.isHittable)
        choice.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let expected = "我想从一件很小的事开始，你帮我选一个吧。"
        XCTAssertEqual(composer.value as? String, expected)
        XCTAssertFalse(app.staticTexts["这是界面预览中的示例回答。"].exists, "Picking a reply must not send a message.")
        composer.typeText("我改了一句。")
        XCTAssertEqual(composer.value as? String, expected + "我改了一句。")
        app.buttons["发送消息"].tap()
        XCTAssertTrue(app.staticTexts["这是界面预览中的示例回答。"].waitForExistence(timeout: 5))
        capture(app, name: "edited-suggested-reply-sent")
    }

    @MainActor func testNewConversationDoesNotCarryPreviousReplySuggestions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-reply-suggestions", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["reply-suggestion-0"].waitForExistence(timeout: 5))
        app.buttons["新建对话"].tap()
        XCTAssertFalse(app.buttons["reply-suggestion-0"].exists)
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse((composer.value as? String ?? "").contains("我想从一件很小的事开始"))
    }

    @MainActor func testMultilineComposerTracksKeyboardHeightAndCanSend() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-long", "--preview-multiline-keyboard", "--preview-tall-keyboard",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        if !app.keyboards.firstMatch.exists { field.tap() }
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        let top = app.descendants(matching: .any).matching(identifier: "preview-keyboard-top").firstMatch
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        let send = app.buttons["发送消息"]
        XCTAssertGreaterThan(field.frame.height, 60, "The regression must exercise a multiline composer.")
        XCTAssertTrue(send.isEnabled && send.isHittable)
        XCTAssertLessThanOrEqual(send.frame.maxY, top.frame.minY - 4)
        capture(app, name: "multiline-above-tall-keyboard")
        let previousTop = top.frame.minY
        app.buttons["expand-preview-keyboard"].tap()
        let taller = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in top.frame.minY < previousTop - 50 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [taller], timeout: 4), .completed, "The keyboard must actually become taller.")
        XCTAssertTrue(send.isHittable)
        XCTAssertLessThanOrEqual(send.frame.maxY, top.frame.minY - 4)
        capture(app, name: "multiline-above-expanded-keyboard")
        app.buttons["expand-preview-keyboard"].tap()
        let smaller = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(top.frame.minY - previousTop) < 8
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [smaller], timeout: 4), .completed)
        XCTAssertTrue(send.isHittable)
        XCTAssertLessThanOrEqual(send.frame.maxY, top.frame.minY - 4)
        XCTAssertGreaterThan(send.frame.maxY, top.frame.minY - 90, "Composer must follow a shrinking keyboard, not retain the old lift.")

        send.tap()
        XCTAssertTrue(app.staticTexts["这是界面预览中的示例回答。"].waitForExistence(timeout: 5))
        capture(app, name: "sent-after-keyboard-height-change")
    }

    @MainActor func testTypingMultipleLinesInNewChatKeepsSendReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-empty", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("111\n222\n333\n444\n555\n666")
        let keyboard = app.keyboards.firstMatch
        let send = app.buttons["发送消息"]
        XCTAssertGreaterThan(field.frame.height, 60)
        XCTAssertTrue(send.isEnabled && send.isHittable)
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY - 4)
        capture(app, name: "new-chat-multiline-keyboard")
        send.tap()
        XCTAssertTrue(app.staticTexts["这是界面预览中的示例回答。"].waitForExistence(timeout: 5))
    }

    @MainActor private func launchLegacyHistory() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-legacy-history", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.scrollViews["chat-scroll"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor func testRetriesKeepOneCleanHistoryEntry() {
        let app = launchLegacyHistory()
        for _ in 0..<3 {
            let retry = app.buttons["重新生成"]
            XCTAssertTrue(retry.waitForExistence(timeout: 3))
            retry.tap()
            XCTAssertTrue(app.staticTexts["这是界面预览中的示例回答。"].waitForExistence(timeout: 3))
        }
        app.buttons["打开历史对话"].tap()
        XCTAssertTrue(app.buttons["sidebar-new-chat"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: "history-thread-row").count, 2)
        XCTAssertTrue(app.staticTexts["读书计划"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", " · 重试")).firstMatch.exists)
        capture(app, name: "clean-history-after-retries")
    }

    @MainActor func testEditingAnswerUpdatesCurrentConversationWithoutAnotherRow() {
        let app = launchLegacyHistory()
        app.buttons["编辑回答"].tap()
        let editor = app.textViews["message-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        let oldText = (editor.value as? String) ?? ""
        editor.typeText("123")
        let editedText = (editor.value as? String) ?? ""
        XCTAssertNotEqual(editedText, oldText)
        XCTAssertTrue(editedText.contains("123"))
        app.navigationBars["编辑回答"].buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[editedText].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["最新的读书计划回答。"].exists)
        app.buttons["打开历史对话"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "history-thread-row").count, 2)
        XCTAssertTrue(app.staticTexts["读书计划"].exists)
        capture(app, name: "clean-history-after-edit")
    }

    @MainActor private func launchLongChat() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-long", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.scrollViews["chat-scroll"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testRightHalfSwipeOpensAndClosesSidebar() {
        let app = launchLongChat()
        let close = app.buttons["sidebar-new-chat"]
        XCTAssertFalse(close.isHittable, "The sidebar starts closed.")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.43))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.43))
        start.press(forDuration: 0.02, thenDragTo: end)
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 4), .completed, "A right-half swipe must open the sidebar without starting at the edge.")
        capture(app, name: "sidebar-opened-from-right-half")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.66, dy: 0.43))
            .press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.43)))
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 4), .completed)
        capture(app, name: "sidebar-closed-after-left-swipe")
    }

    @MainActor func testFullHeightVerticalScrollKeepsLastLineReadable() {
        let app = launchLongChat()
        let scroll = app.scrollViews["chat-scroll"]
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-panel").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Settings moved into the sidebar; there is no tab bar.")
        XCTAssertGreaterThan(scroll.frame.maxY, app.frame.maxY - 40, "The scroll view must continue behind the floating composer.")

        let end = app.staticTexts["滚动检查结束"]
        for index in 0..<10 {
            if end.isHittable && end.frame.maxY < composer.frame.minY { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.68))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.22)))
            if index == 0 { capture(app, name: "full-height-mid-scroll") }
        }
        XCTAssertFalse(app.buttons["sidebar-new-chat"].isHittable, "Vertical scrolling must not open the sidebar.")
        XCTAssertTrue(end.isHittable, "The last line must be reachable.")
        XCTAssertLessThan(end.frame.maxY, composer.frame.minY, "The last line must be readable above the composer.")
        capture(app, name: "last-line-above-floating-controls")
    }

    @MainActor func testKeyboardHidesNavigationAndKeepsComposerVisible() {
        let app = launchLongChat()
        let field = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-panel").firstMatch
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY + 3)
        capture(app, name: "keyboard-and-floating-composer")
    }

    @MainActor func testSendingKeepsTheNewReplyAboveComposer() {
        let app = launchLongChat()
        let field = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        field.tap()
        field.typeText("123")
        app.buttons["发送消息"].tap()
        let reply = app.staticTexts["这是界面预览中的示例回答。"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertTrue(reply.isHittable)
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-panel").firstMatch
        XCTAssertLessThan(reply.frame.maxY, composer.frame.minY, "New replies must scroll into the readable area above the composer.")
        capture(app, name: "new-reply-above-composer")
    }

    @MainActor func testSidebarAvatarOpensSettingsWithUsageCalendar() {
        let app = launchLongChat()
        app.buttons["打开历史对话"].tap()
        let profile = app.buttons["sidebar-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 3))
        profile.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "usage-calendar").firstMatch.waitForExistence(timeout: 4))
        capture(app, name: "settings-from-sidebar")
    }

    @MainActor func testComposerPillShowsModelAndThinkingLevel() {
        let app = launchLongChat()
        let pill = app.buttons["model-effort-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 4))
        XCTAssertEqual(pill.value as? String, "Flash High", "One pill carries the model and the English thinking level.")
    }

    @MainActor func testProjectChatsStayOutOfRecentsAndBulkMoveWorks() {
        let app = launchLongChat()
        app.buttons["打开历史对话"].tap()
        XCTAssertTrue(app.buttons["sidebar-new-chat"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["张居正改革的得失"].exists, "Conversations inside a project must not show in recents.")
        let before = app.buttons.matching(identifier: "history-thread-row").count
        XCTAssertGreaterThan(before, 0)
        app.buttons["sidebar-all-chats"].tap()
        let select = app.buttons["all-chats-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 4))
        select.tap()
        app.buttons["all-chats-select-all"].tap()
        app.buttons["all-chats-move"].tap()
        // The pinned project in the sidebar carries the same name; pick the menu item.
        let target = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "明史研读", "sidebar-pinned-project")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        target.tap()
        capture(app, name: "all-chats-after-bulk-move")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sidebar-new-chat"].waitForExistence(timeout: 4))
        let emptied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons.matching(identifier: "history-thread-row").count == 0 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [emptied], timeout: 4), .completed, "Moved conversations leave recents.")
        capture(app, name: "recents-after-bulk-move")
    }

    @MainActor func testProjectPageListsItsConversationsAndPinnedProjectFoldsOut() {
        let app = launchLongChat()
        app.buttons["打开历史对话"].tap()
        let pinned = app.buttons["sidebar-pinned-project"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 3))
        pinned.tap()
        XCTAssertTrue(app.staticTexts["张居正改革的得失"].waitForExistence(timeout: 3), "A pinned project folds out its conversations.")
        capture(app, name: "sidebar-pinned-project-open")
        app.buttons["sidebar-projects"].tap()
        let projectRow = app.buttons.matching(identifier: "project-row").firstMatch
        XCTAssertTrue(projectRow.waitForExistence(timeout: 4))
        projectRow.tap()
        XCTAssertTrue(app.buttons["project-new-chat"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["project-files"].exists && app.buttons["project-instructions-button"].exists)
        let thread = app.buttons.matching(identifier: "project-thread-row").firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 3), "The project page lists the conversations inside it.")
        capture(app, name: "project-page")
        thread.tap()
        XCTAssertTrue(app.staticTexts["张居正改革为什么人亡政息？"].waitForExistence(timeout: 5))
    }
}
