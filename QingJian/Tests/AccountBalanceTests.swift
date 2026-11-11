import XCTest
@testable import DeepSeekCore

final class AccountBalanceTests: XCTestCase {
    func testOfficialBalanceResponsePreservesBothCurrencies() throws {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},{"currency":"USD","total_balance":"0.001","granted_balance":"0.00","topped_up_balance":"0.001"}]}"#
        let balance = try JSONDecoder().decode(AccountBalance.self, from: Data(json.utf8))
        XCTAssertTrue(balance.isAvailable)
        XCTAssertEqual(balance.balances.map(\.currency), ["CNY", "USD"])
        XCTAssertEqual(balance.balances.map(\.totalBalance), ["110.00", "0.001"])
    }

    func testAvailabilityUsesServerFlagRatherThanDisplayedAmount() throws {
        let json = #"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"1.00"}]}"#
        let balance = try JSONDecoder().decode(AccountBalance.self, from: Data(json.utf8))
        XCTAssertFalse(balance.isAvailable)
    }

    func testMissingAvailabilityCannotBeReportedAsValidConnection() {
        let json = #"{"error":{"message":"Authentication failed"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AccountBalance.self, from: Data(json.utf8)))
    }
}
