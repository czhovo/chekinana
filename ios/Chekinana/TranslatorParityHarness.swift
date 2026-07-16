import Foundation

private struct Fixture: Decodable {
    let category: String
    let text: String
    let expectedCommand: String?
    let expectedClarification: Bool

    enum CodingKeys: String, CodingKey {
        case category
        case text
        case expectedCommand = "expected_command"
        case expectedClarification = "expected_clarification"
    }
}

@main
private enum TranslatorParityHarness {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: parity-harness <fixture.json>\n".utf8))
            exit(2)
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
        var failures: [(Fixture, ChekinanaNaturalLanguageTranslation)] = []
        var coveredCommands: Set<String> = []
        var safeClarifications = 0
        var parserRoundTrips = 0

        for fixture in fixtures {
            let result = ChekinanaNaturalLanguageTranslator.translate(fixture.text)
            if let command = fixture.expectedCommand?.split(separator: " ").first {
                coveredCommands.insert(String(command))
            }
            if fixture.expectedClarification, result.needsClarification, result.command == nil {
                safeClarifications += 1
            }
            if let command = result.command, (try? ChekinanaCommandParser.parse(command)) != nil {
                parserRoundTrips += 1
            }
            if result.command != fixture.expectedCommand || result.needsClarification != fixture.expectedClarification {
                failures.append((fixture, result))
            }
        }

        let expectedCommands = Set(ChekinanaNaturalLanguageTranslator.commandNames)
        print("total=\(fixtures.count) passed=\(fixtures.count - failures.count) failed=\(failures.count)")
        print("clarification_safe=\(safeClarifications)/\(fixtures.filter(\.expectedClarification).count)")
        print("commands_covered=\(coveredCommands.count)/\(expectedCommands.count)")
        print("parser_roundtrips=\(parserRoundTrips)/\(fixtures.filter { $0.expectedCommand != nil }.count)")
        if coveredCommands != expectedCommands {
            print("missing_commands=\(expectedCommands.subtracting(coveredCommands).sorted())")
        }
        for (fixture, result) in failures.prefix(30) {
            print("FAIL [\(fixture.category)] \(fixture.text.debugDescription)")
            print("  expected=\(fixture.expectedCommand ?? "nil") clarify=\(fixture.expectedClarification)")
            print("  actual=\(result.command ?? "nil") clarify=\(result.needsClarification) message=\(result.message)")
        }
        if !failures.isEmpty || coveredCommands != expectedCommands || parserRoundTrips != fixtures.filter({ $0.expectedCommand != nil }).count {
            exit(1)
        }
    }
}
