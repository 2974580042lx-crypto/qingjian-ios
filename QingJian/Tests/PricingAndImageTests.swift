import XCTest
@testable import DeepSeekCore

final class PricingAndImageTests: XCTestCase {
    private func beijing(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        return try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    func testPeakHoursFollowBeijingWeekdays() throws {
        // 2026-10-12 is a Monday, 2026-10-11 a Sunday.
        XCTAssertTrue(Pricing.isPeak(try beijing(2026, 10, 12, 10)))
        XCTAssertTrue(Pricing.isPeak(try beijing(2026, 10, 12, 17)))
        XCTAssertFalse(Pricing.isPeak(try beijing(2026, 10, 12, 13)))
        XCTAssertFalse(Pricing.isPeak(try beijing(2026, 10, 12, 18)))
        XCTAssertFalse(Pricing.isPeak(try beijing(2026, 10, 11, 10)))
    }

    func testCostSplitsCachedInputAndOutput() throws {
        let usage = TokenUsage(promptTokens: 1_000_000, completionTokens: 500_000, cachedTokens: 400_000)
        let offPeak = Pricing.cost(model: .flash, usage: usage, at: try beijing(2026, 10, 11, 10))
        let peak = Pricing.cost(model: .flash, usage: usage, at: try beijing(2026, 10, 12, 10))
        XCTAssertEqual(offPeak, 2.608, accuracy: 0.000001)
        XCTAssertEqual(peak, 5.216, accuracy: 0.000001)
        XCTAssertEqual(Pricing.label(0.00412), "¥0.0041")
        XCTAssertEqual(Pricing.label(1.2341), "¥1.234")
    }

    func testPicturesEncodeAsContentBlocksOnlyWhenLoaded() throws {
        var question = ChatMessage(role: .user, content: "这是什么？")
        question.images = ["a.jpg"]
        let withPictures = ChatRequest(settings: AppSettings(), messages: [question], imageLoader: { "data:image/jpeg;base64," + $0 })
        XCTAssertEqual(withPictures.messages.last?.content, "这是什么？")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(withPictures)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.first?["content"] is String)
        let blocks = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(blocks[0]["text"] as? String, "这是什么？")
        XCTAssertEqual(blocks[1]["type"] as? String, "image_url")
        XCTAssertEqual((blocks[1]["image_url"] as? [String: Any])?["url"] as? String, "data:image/jpeg;base64,a.jpg")

        let textOnly = ChatRequest(settings: AppSettings(), messages: [question])
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(textOnly)) as? [String: Any])
        let plainMessages = try XCTUnwrap(plain["messages"] as? [[String: Any]])
        XCTAssertEqual(plainMessages.last?["content"] as? String, "这是什么？")
    }

    func testOnlyTheLatestPictureMessagesTravel() {
        var history: [ChatMessage] = []
        for index in 0..<6 {
            var question = ChatMessage(role: .user, content: "图 \(index)")
            question.images = ["\(index).jpg"]
            history.append(question)
            history.append(ChatMessage(role: .assistant, content: "答 \(index)"))
        }
        let request = ChatRequest(settings: AppSettings(), messages: history, imageLoader: { $0 })
        let sent = request.messages.flatMap(\.images)
        XCTAssertEqual(sent, ["2.jpg", "3.jpg", "4.jpg", "5.jpg"])
    }

    func testOldRecordsWithoutPicturesOrModelStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","content":"旧回答","reasoning":"","createdAt":0,"state":"complete"}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        XCTAssertNil(message.images)
        XCTAssertNil(message.model)
        XCTAssertEqual(message.content, "旧回答")
    }
}
