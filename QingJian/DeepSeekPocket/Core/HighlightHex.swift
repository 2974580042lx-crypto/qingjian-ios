import Foundation

enum HighlightHex {
    static func normalized(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard (value.count == 3 || value.count == 6),
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) }) else { return nil }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        return "#" + value.uppercased()
    }
    static func rgb(_ input: String) -> UInt32? {
        guard let value = normalized(input) else { return nil }
        return UInt32(value.dropFirst(), radix: 16)
    }
}
