import Foundation

// MCCS capability strings advertise VCP features and discrete values. Continuous
// feature maxima come from Get VCP, never from a monitor-model lookup table.
struct DDCCapabilities {
    let raw: String
    let features: [UInt8: [UInt8]]
    let commands: Set<UInt8>

    init?(_ raw: String) {
        guard raw.utf8.count <= 4096 else { return nil }
        var depth = 0
        for character in raw {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1; if depth < 0 { return nil } }
        }
        guard depth == 0, let vcp = Self.group("vcp", in: raw) else { return nil }
        let tokens = vcp.replacingOccurrences(of: "(", with: " ( ").replacingOccurrences(of: ")", with: " ) ")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var features: [UInt8: [UInt8]] = [:], index = 0
        while index < tokens.count {
            guard let code = Self.hex(tokens[index]) else { return nil }
            index += 1
            var values: [UInt8] = []
            if index < tokens.count && tokens[index] == "(" {
                index += 1
                while index < tokens.count && tokens[index] != ")" {
                    guard let value = Self.hex(tokens[index]) else { return nil }
                    values.append(value); index += 1
                }
                guard index < tokens.count else { return nil }
                index += 1
            }
            features[code] = values
        }
        self.raw = raw
        self.features = features
        self.commands = Set((Self.group("cmds", in: raw) ?? "").split(whereSeparator: { $0.isWhitespace }).compactMap { Self.hex(String($0)) })
    }
    private static func hex(_ token: String) -> UInt8? {
        guard token.count == 2 else { return nil }
        return UInt8(token, radix: 16)
    }
    private static func group(_ name: String, in raw: String) -> String? {
        guard let range = raw.range(of: "\\b" + name + "\\s*\\(", options: [.regularExpression, .caseInsensitive]) else { return nil }
        var depth = 1, cursor = range.upperBound
        let start = cursor
        while cursor < raw.endIndex {
            if raw[cursor] == "(" { depth += 1 }
            if raw[cursor] == ")" { depth -= 1; if depth == 0 { return String(raw[start..<cursor]) } }
            cursor = raw.index(after: cursor)
        }
        return nil
    }
}
