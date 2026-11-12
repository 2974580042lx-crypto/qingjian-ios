import XCTest
import Foundation
@testable import DeepSeekCore

final class ProjectToolAccessTests: XCTestCase {
    func testGitHubOnlyProjectRejectsDriveWebAndUnknownCalls() throws {
        var project = ChatProject(name: "代码")
        project.githubTools = true
        let access = ProjectToolAccess(project: project, provider: .deepSeek)
        XCTAssertNoThrow(try access.require("github_write"))
        XCTAssertNoThrow(try access.require("github_read"))
        for name in ["drive_read", "drive_write", "web_read", "web_search", "github_merge"] {
            XCTAssertThrowsError(try access.require(name), name)
        }
    }

    func testMissingProjectAndSubscriptionSupportConnectedDefaultsWhileRespectingExplicitOptOut() throws {
        var project = ChatProject(name: "工具")
        project.driveTools = true; project.githubTools = true; project.webTools = true
        // ChatGPT Subscription and non-project chats with connected credentials can use tools by default
        let subAccess = ProjectToolAccess(project: project, provider: .chatGPT)
        let nonProjectConnected = ProjectToolAccess(
            project: nil,
            provider: .chatGPT,
            driveDefault: true,
            githubDefault: true,
            webDefault: true
        )
        for access in [subAccess, nonProjectConnected] {
            for name in ["github_read", "drive_read", "web_search", "web_read"] {
                XCTAssertNoThrow(try access.require(name))
            }
        }
        // Without connected defaults or project flags, tools remain off; explicit false overrides connected defaults
        let disconnected = ProjectToolAccess(project: nil, provider: .deepSeek)
        for name in ["github_read", "drive_read", "web_search"] {
            XCTAssertThrowsError(try disconnected.require(name))
        }
        project.githubTools = false
        let optedOut = ProjectToolAccess(project: project, provider: .chatGPT, githubDefault: true)
        XCTAssertThrowsError(try optedOut.require("github_read"))
    }

    func testTurningOffToolsWhileApprovalWaitsRevokesAccess() throws {
        var project = ChatProject(name: "代码")
        project.githubTools = true
        XCTAssertNoThrow(try ProjectToolAccess(project: project, provider: .deepSeek).require("github_write"))
        project.githubTools = false
        XCTAssertThrowsError(try ProjectToolAccess(project: project, provider: .deepSeek).require("github_write"))
    }

    func testEachEnabledToolFamilyRemainsUsable() throws {
        var project = ChatProject(name: "工具")
        project.driveTools = true; project.githubTools = true; project.webTools = true
        let access = ProjectToolAccess(project: project, provider: .deepSeek)
        for spec in DriveTools.specs + GitHubTools.specs + WebTools.specs {
            XCTAssertNoThrow(try access.require(spec.name), spec.name)
        }
    }
}

final class ProjectPromptTemplateTests: XCTestCase {
    private let context = PromptVariables.Context(now: Date(timeIntervalSince1970: 1_792_245_900), userName: "小龙", modelName: "Flash")

    func testOnlyInstructionsExpandWhileDocumentsAndMemoryStayLiteral() {
        var project = ChatProject(name: "模板", instructions: "你好 {{名字}}，使用 {{model}}。")
        project.documents = [ProjectDocument(name: "{{user}} 模板", text: "示例 {{时间}} 和 {{名字}}")]
        project.memory = "保留 {{date}}"
        let original = project
        let prompt = project.systemPrompt(resolving: context)
        XCTAssertTrue(prompt.contains("你好 小龙，使用 Flash。"))
        XCTAssertTrue(prompt.contains("《{{user}} 模板》\n示例 {{时间}} 和 {{名字}}"))
        XCTAssertTrue(prompt.contains("保留 {{date}}"))
        XCTAssertEqual(project, original)
    }

    func testManualKeepsVariableExamplesInActualRequest() {
        let project = AppManual.newProject()
        let request = ChatRequest(settings: AppSettings(), messages: [ChatMessage(role: .user, content: "怎么用变量？")],
                                  systemPrompt: project.systemPrompt(resolving: context))
        let prompt = request.messages.first?.content ?? ""
        XCTAssertTrue(prompt.contains("{{时间}}"))
        XCTAssertTrue(prompt.contains("{{user}}"))
        XCTAssertTrue(prompt.contains(AppManual.document))
    }
}

final class PublicWebAddressTests: XCTestCase {
    func testRejectsPrivateReservedAndEmbeddedAddressForms() {
        for address in ["0.0.0.0", "10.1.2.3", "127.0.0.1", "169.254.169.254", "172.16.1.1", "192.168.0.1",
                        "100.64.1.2", "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255",
                        "::", "::1", "fe80::1", "fd00::1", "ff02::1", "::ffff:127.0.0.1", "64:ff9b::a00:1", "2002:7f00:1::", "2001:db8::1"] {
            XCTAssertFalse(PublicWebAddress.isPublicIPAddress(address), address)
        }
        for address in ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
            XCTAssertTrue(PublicWebAddress.isPublicIPAddress(address), address)
        }
    }

    func testPublicLookingDomainWithAnyPrivateDNSAnswerIsRejected() async {
        for answers in [["127.0.0.1"], ["8.8.8.8", "192.168.1.2"], ["fd00::1"], ["::ffff:10.0.0.1"], []] {
            do {
                try await PublicWebAddress.validate(URL(string: "https://public-looking.example/page")!, resolver: { _ in answers })
                XCTFail("Accepted DNS answers: \(answers)")
            } catch {}
        }
    }

    func testPublicIPv4AndIPv6AnswersAreAllowed() async throws {
        try await PublicWebAddress.validate(URL(string: "https://example.com")!, resolver: { _ in
            ["1.1.1.1", "2606:4700:4700::1111"]
        })
    }

    func testRedirectToDomainResolvingPrivatelyIsBlockedWithoutNetwork() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let initial = URL(string: "https://example.com")!
        let delegate = PublicRedirectsOnly(resolver: { _ in ["10.0.0.9"] })
        let request: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: session.dataTask(with: initial),
                                willPerformHTTPRedirection: HTTPURLResponse(url: initial, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                                newRequest: URLRequest(url: URL(string: "https://other.example/private")!),
                                completionHandler: { continuation.resume(returning: $0) })
        }
        XCTAssertNil(request)
    }
}
