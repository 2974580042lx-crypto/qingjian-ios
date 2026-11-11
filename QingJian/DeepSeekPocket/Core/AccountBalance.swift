import Foundation

struct AccountBalance: Decodable, Sendable {
    let isAvailable: Bool
    let balances: [Amount]

    struct Amount: Decodable, Sendable {
        let currency: String
        let totalBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
        }
    }

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balances = "balance_infos"
    }

    var summary: String {
        balances.map { amount in
            switch amount.currency {
            case "CNY": return "\(amount.totalBalance) 元"
            case "USD": return "\(amount.totalBalance) 美元"
            default: return "\(amount.totalBalance) \(amount.currency)"
            }
        }.joined(separator: " · ")
    }
}
