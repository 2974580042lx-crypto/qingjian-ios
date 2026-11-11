import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A hostname alone does not establish that a page is public. Check every
/// address returned by DNS, both before the initial request and each redirect.
enum PublicWebAddress {
    typealias Resolver = @Sendable (String) async throws -> [String]

    static func validate(_ url: URL, resolver: Resolver = resolve) async throws {
        guard WebText.isFetchable(url), let host = url.host else { throw WebPageError.notAllowed }
        let addresses = try await resolver(host)
        try Task.checkCancellation()
        guard !addresses.isEmpty, addresses.allSatisfy(isPublicIPAddress) else { throw WebPageError.notAllowed }
    }

    static func isPublicIPAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let b = withUnsafeBytes(of: v4) { Array($0) }
            switch (b[0], b[1], b[2]) {
            case (0, _, _), (10, _, _), (127, _, _), (169, 254, _), (172, 16...31, _),
                 (100, 64...127, _), (192, 168, _), (192, 0, 0), (192, 0, 2),
                 (192, 88, 99), (198, 18...19, _), (198, 51, 100), (203, 0, 113):
                return false
            default:
                return b[0] < 224
            }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        // Only global unicast. This also excludes loopback, link-local, ULA,
        // multicast, IPv4-mapped and NAT64 encodings of private addresses.
        guard b[0] & 0xE0 == 0x20 else { return false }
        if b[0] == 0x20 && b[1] == 0x01 {
            if b[2] < 2 { return false } // special-use 2001::/23
            if b[2] == 0x0D && b[3] == 0xB8 { return false } // documentation
        }
        if b[0] == 0x20 && b[1] == 0x02 { return false } // 6to4 embeds IPv4
        if b[0] == 0x3F && b[1] == 0xFF && b[2] < 0x10 { return false } // documentation
        return true
    }

    static func resolve(_ host: String) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            #if canImport(Darwin)
            hints.ai_socktype = SOCK_STREAM
            #else
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #endif
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { throw WebPageError.notAllowed }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var next: UnsafeMutablePointer<addrinfo>? = first
            while let entry = next {
                defer { next = entry.pointee.ai_next }
                guard let address = entry.pointee.ai_addr else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: buffer))
                }
            }
            return addresses
        }.value
    }
}
