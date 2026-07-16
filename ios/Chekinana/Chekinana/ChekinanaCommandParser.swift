import Foundation

struct ChekinanaParsedCommand {
    let name: String
    let target: String?
    let arguments: [String: String]
}

enum ChekinanaCommandParseError: LocalizedError {
    case empty
    case unterminatedQuote
    case duplicateKey(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "empty command"
        case .unterminatedQuote:
            "unterminated quote"
        case .duplicateKey(let key):
            "duplicate argument: \(key)"
        case .invalidArgument(let value):
            "invalid argument: \(value)"
        }
    }
}

enum ChekinanaCommandParser {
    static func parse(_ input: String) throws -> ChekinanaParsedCommand {
        let tokens = try tokenize(input)
        guard let command = tokens.first?.lowercased() else {
            throw ChekinanaCommandParseError.empty
        }

        var target: String?
        var arguments: [String: String] = [:]

        for token in tokens.dropFirst() {
            if command == "addevent",
               target == nil,
               token.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
                target = token
                continue
            }
            if let separatorIndex = token.firstIndex(of: "=") {
                let key = String(token[..<separatorIndex]).lowercased()
                let valueStart = token.index(after: separatorIndex)
                let value = String(token[valueStart...])

                guard !key.isEmpty else {
                    throw ChekinanaCommandParseError.invalidArgument(token)
                }
                guard arguments[key] == nil else {
                    throw ChekinanaCommandParseError.duplicateKey(key)
                }

                arguments[key] = value
            } else if target == nil {
                target = token
            } else {
                throw ChekinanaCommandParseError.invalidArgument(token)
            }
        }

        return ChekinanaParsedCommand(name: command, target: target, arguments: arguments)
    }

    private static func tokenize(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false

        for character in input {
            if character == "\"" {
                isQuoted.toggle()
                continue
            }

            if character.isWhitespace && !isQuoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if isQuoted {
            throw ChekinanaCommandParseError.unterminatedQuote
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
