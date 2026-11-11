import Foundation
import CryptoKit

// "Sign in with Google" for an iOS OAuth client: authorization code with PKCE,
// no client secret. The redirect is the client ID reversed as a URL scheme,
// which ASWebAuthenticationSession catches without registering it in Info.plist.
enum GoogleOAuth {
    static let clientID = "449575043400-ugf9rn7nh5j3t7em00rla2o4ehrqgjpt.apps.googleusercontent.com"
    static var callbackScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    static var redirectURI: String { callbackScheme + ":/oauth2redirect" }
    // Full Drive access, plus the e-mail address to show which account is linked.
    static let scope = "openid email https://www.googleapis.com/auth/drive"
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    static func authorizationURL(state: String, verifier: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// The authorization code from the redirect, after checking it is ours.
    static func code(from callback: URL, state: String) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == callbackScheme.lowercased() else { throw GoogleAuthError.invalidCallback }
        let items = parts.queryItems ?? []
        func single(_ name: String) throws -> String? {
            let values = items.filter { $0.name == name }
            guard values.count <= 1 else { throw GoogleAuthError.invalidCallback }
            return values.first?.value
        }
        guard try single("state") == state else { throw GoogleAuthError.invalidCallback }
        if let error = try single("error") {
            throw error == "access_denied" ? GoogleAuthError.denied : GoogleAuthError.service(error)
        }
        guard let code = try single("code"), !code.isEmpty, code.count < 4096 else { throw GoogleAuthError.invalidCallback }
        return code
    }

    static func exchangeBody(code: String, verifier: String) -> Data {
        form(["code": code, "client_id": clientID, "redirect_uri": redirectURI,
              "grant_type": "authorization_code", "code_verifier": verifier])
    }

    static func refreshBody(refreshToken: String) -> Data {
        form(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    static func form(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = values.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// The e-mail claim of an ID token, for display only (the token came straight
    /// from Google's token endpoint over HTTPS, so it is not verified again here).
    static func email(fromIDToken token: String?) -> String? {
        guard let token else { return nil }
        let pieces = token.split(separator: ".")
        guard pieces.count == 3, let data = Data(base64URL: String(pieces[1])),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }
}

struct GoogleTokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int?
    let refreshToken: String?
    let idToken: String?
    let scope: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token"
        case idToken = "id_token", scope
    }
}

/// What is kept in the Keychain between launches.
struct GoogleCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String?
    var grantedDrive: Bool

    /// A refreshed response may omit the refresh token; the old one stays valid then.
    func updated(with response: GoogleTokenResponse, now: Date = Date()) -> GoogleCredentials {
        var next = self
        next.accessToken = response.accessToken
        next.expiresAt = now.addingTimeInterval(TimeInterval(response.expiresIn ?? 3600))
        if let refresh = response.refreshToken, !refresh.isEmpty { next.refreshToken = refresh }
        if let scope = response.scope { next.grantedDrive = GoogleCredentials.hasDrive(scope) }
        return next
    }

    static func hasDrive(_ scope: String) -> Bool {
        scope.split(separator: " ").contains("https://www.googleapis.com/auth/drive")
    }

    var isFresh: Bool { expiresAt.timeIntervalSinceNow > 60 }
}

enum GoogleAuthError: LocalizedError, Equatable {
    case invalidCallback, denied, cancelled, noRefreshToken, driveNotGranted, signInRequired
    case service(String), storage(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidCallback: return "谷歌登录返回的信息无法核对，请重新登录。"
        case .denied: return "你在谷歌页面上没有允许访问。"
        case .cancelled: return "已取消谷歌登录。"
        case .noRefreshToken: return "谷歌没有返回长期凭证，请在谷歌账号的「第三方应用」里移除 Sermo 后重新登录。"
        case .driveNotGranted: return "登录时没有勾选云盘权限。请重新登录，并在授权页勾选访问谷歌云盘。"
        case .signInRequired: return "谷歌云盘未登录或登录已过期，请在设置里重新登录。"
        case .service(let code): return "谷歌登录失败（\(code)）。"
        case .storage(let status): return "无法读取或保存谷歌登录凭证（\(status)），请解锁手机后重试。"
        }
    }
}
