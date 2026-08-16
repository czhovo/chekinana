import Foundation

struct MatchGamePosition: Hashable, Sendable {
    let row: Int
    let column: Int
}

struct MatchGameMove: Equatable, Sendable {
    let first: MatchGamePosition
    let second: MatchGamePosition
    let path: [MatchGamePosition]
}

struct MatchGameEngine: Equatable, Sendable {
    static let rowCount = 12
    static let columnCount = 8

    private(set) var board: [[Int]]

    init(board: [[Int]]) {
        precondition(board.count == Self.rowCount)
        precondition(board.allSatisfy { $0.count == Self.columnCount })
        self.board = board
    }

    var remainingPairs: Int {
        board.reduce(into: 0) { total, row in
            total += row.lazy.filter { $0 != 0 }.count
        } / 2
    }

    var isComplete: Bool {
        remainingPairs == 0
    }

    func tile(at position: MatchGamePosition) -> Int {
        guard Self.contains(position) else { return 0 }
        return board[position.row][position.column]
    }

    func connectionPath(
        from first: MatchGamePosition,
        to second: MatchGamePosition
    ) -> [MatchGamePosition]? {
        guard Self.contains(first), Self.contains(second), first != second else { return nil }

        let firstTile = tile(at: first)
        guard firstTile != 0, firstTile == tile(at: second) else { return nil }

        func isBlocked(_ position: MatchGamePosition) -> Bool {
            guard Self.contains(position) else { return false }
            guard position != first, position != second else { return false }
            return tile(at: position) != 0
        }

        if isStraightClear(from: first, to: second, isBlocked: isBlocked) {
            return [first, second]
        }

        let firstCorner = MatchGamePosition(row: first.row, column: second.column)
        if Self.isInsideExpandedBoard(firstCorner),
           isStraightClear(from: first, to: firstCorner, isBlocked: isBlocked),
           isStraightClear(from: firstCorner, to: second, isBlocked: isBlocked) {
            return Self.compressed([first, firstCorner, second])
        }

        let secondCorner = MatchGamePosition(row: second.row, column: first.column)
        if Self.isInsideExpandedBoard(secondCorner),
           isStraightClear(from: first, to: secondCorner, isBlocked: isBlocked),
           isStraightClear(from: secondCorner, to: second, isBlocked: isBlocked) {
            return Self.compressed([first, secondCorner, second])
        }

        var bestRowPath: [MatchGamePosition]?
        var bestRowScore = Double.infinity
        let middleRow = Double(first.row + second.row) / 2
        for row in -1...Self.rowCount {
            let a = MatchGamePosition(row: row, column: first.column)
            let b = MatchGamePosition(row: row, column: second.column)
            guard isStraightClear(from: first, to: a, isBlocked: isBlocked),
                  isStraightClear(from: a, to: b, isBlocked: isBlocked),
                  isStraightClear(from: b, to: second, isBlocked: isBlocked) else {
                continue
            }

            let boundaryPenalty = (row == -1 || row == Self.rowCount) ? 500 : 0
            let distance = abs(row - first.row) + abs(second.row - row) + abs(first.column - second.column)
            let score = Double(distance + boundaryPenalty) + abs(Double(row) - middleRow)
            if score < bestRowScore {
                bestRowScore = score
                bestRowPath = [first, a, b, second]
            }
        }
        if let bestRowPath {
            return Self.compressed(bestRowPath)
        }

        var bestColumnPath: [MatchGamePosition]?
        var bestColumnScore = Double.infinity
        let middleColumn = Double(first.column + second.column) / 2
        for column in -1...Self.columnCount {
            let a = MatchGamePosition(row: first.row, column: column)
            let b = MatchGamePosition(row: second.row, column: column)
            guard isStraightClear(from: first, to: a, isBlocked: isBlocked),
                  isStraightClear(from: a, to: b, isBlocked: isBlocked),
                  isStraightClear(from: b, to: second, isBlocked: isBlocked) else {
                continue
            }

            let boundaryPenalty = (column == -1 || column == Self.columnCount) ? 500 : 0
            let distance = abs(column - first.column) + abs(second.column - column) + abs(first.row - second.row)
            let score = Double(distance + boundaryPenalty) + abs(Double(column) - middleColumn)
            if score < bestColumnScore {
                bestColumnScore = score
                bestColumnPath = [first, a, b, second]
            }
        }
        return bestColumnPath.map(Self.compressed)
    }

    mutating func remove(_ move: MatchGameMove) -> Bool {
        guard connectionPath(from: move.first, to: move.second) != nil else { return false }
        board[move.first.row][move.first.column] = 0
        board[move.second.row][move.second.column] = 0
        return true
    }

    func availableMoves() -> [MatchGameMove] {
        var positionsByTile: [Int: [MatchGamePosition]] = [:]
        for row in board.indices {
            for column in board[row].indices where board[row][column] != 0 {
                positionsByTile[board[row][column], default: []].append(
                    MatchGamePosition(row: row, column: column)
                )
            }
        }

        var moves: [MatchGameMove] = []
        for tile in positionsByTile.keys.sorted() {
            guard let positions = positionsByTile[tile], positions.count >= 2 else { continue }
            for firstIndex in 0..<(positions.count - 1) {
                for secondIndex in (firstIndex + 1)..<positions.count {
                    let first = positions[firstIndex]
                    let second = positions[secondIndex]
                    if let path = connectionPath(from: first, to: second) {
                        moves.append(MatchGameMove(first: first, second: second, path: path))
                    }
                }
            }
        }

        return moves.sorted { lhs, rhs in
            let lhsTurns = max(0, lhs.path.count - 2)
            let rhsTurns = max(0, rhs.path.count - 2)
            if lhsTurns != rhsTurns { return lhsTurns < rhsTurns }
            return Self.pathDistance(lhs.path) < Self.pathDistance(rhs.path)
        }
    }

    private func isStraightClear(
        from start: MatchGamePosition,
        to end: MatchGamePosition,
        isBlocked: (MatchGamePosition) -> Bool
    ) -> Bool {
        guard (start.row == end.row || start.column == end.column),
              Self.isInsideExpandedBoard(start), Self.isInsideExpandedBoard(end) else {
            return false
        }

        let rowStep = (end.row - start.row).signum()
        let columnStep = (end.column - start.column).signum()
        var current = start
        while current != end {
            current = MatchGamePosition(
                row: current.row + rowStep,
                column: current.column + columnStep
            )
            guard Self.isInsideExpandedBoard(current), !isBlocked(current) else { return false }
        }
        return true
    }

    private static func contains(_ position: MatchGamePosition) -> Bool {
        (0..<rowCount).contains(position.row) && (0..<columnCount).contains(position.column)
    }

    private static func isInsideExpandedBoard(_ position: MatchGamePosition) -> Bool {
        (-1...rowCount).contains(position.row) && (-1...columnCount).contains(position.column)
    }

    private static func compressed(_ path: [MatchGamePosition]) -> [MatchGamePosition] {
        guard path.count > 2 else { return path }
        var result = [path[0]]
        for index in 1..<(path.count - 1) {
            let previous = path[index - 1]
            let current = path[index]
            let next = path[index + 1]
            let firstDirection = (
                (current.row - previous.row).signum(),
                (current.column - previous.column).signum()
            )
            let secondDirection = (
                (next.row - current.row).signum(),
                (next.column - current.column).signum()
            )
            if firstDirection != secondDirection {
                result.append(current)
            }
        }
        result.append(path[path.count - 1])
        return result
    }

    private static func pathDistance(_ path: [MatchGamePosition]) -> Int {
        zip(path, path.dropFirst()).reduce(into: 0) { total, pair in
            total += abs(pair.0.row - pair.1.row) + abs(pair.0.column - pair.1.column)
        }
    }
}

enum MatchGameSolver {
    static func solution(for engine: MatchGameEngine, nodeLimit: Int = 650_000) -> [MatchGameMove]? {
        var visited: Set<[[Int]]> = []
        var visitedNodes = 0

        func solve(_ current: MatchGameEngine) -> [MatchGameMove]? {
            if current.isComplete { return [] }
            guard visitedNodes < nodeLimit else { return nil }
            visitedNodes += 1

            guard visited.insert(current.board).inserted else { return nil }
            let moves = current.availableMoves()
            guard !moves.isEmpty else { return nil }

            for move in moves {
                var next = current
                guard next.remove(move) else { continue }
                if let tail = solve(next) {
                    return [move] + tail
                }
            }
            return nil
        }

        return solve(engine)
    }
}

enum MatchGamePresetBoards {
    static let all: [[[Int]]] = [
        [
            [1, 10, 7, 8, 11, 14, 12, 13],
            [4, 6, 3, 12, 7, 9, 2, 13],
            [3, 4, 9, 14, 1, 2, 7, 12],
            [9, 1, 10, 6, 12, 11, 14, 4],
            [5, 8, 2, 4, 3, 6, 10, 3],
            [11, 7, 6, 5, 5, 3, 4, 9],
            [10, 13, 9, 3, 8, 12, 1, 2],
            [2, 7, 10, 12, 6, 1, 8, 1],
            [1, 6, 3, 8, 4, 5, 13, 7],
            [10, 12, 5, 11, 14, 12, 14, 8],
            [13, 3, 7, 9, 2, 10, 7, 11],
            [14, 10, 14, 1, 13, 11, 5, 14],
        ],
        [
            [1, 10, 8, 9, 2, 12, 7, 14],
            [11, 5, 13, 6, 1, 14, 3, 4],
            [9, 3, 1, 7, 9, 6, 4, 10],
            [13, 1, 6, 3, 12, 11, 7, 11],
            [10, 4, 11, 5, 14, 2, 12, 9],
            [8, 7, 2, 10, 10, 9, 8, 13],
            [11, 12, 9, 14, 8, 13, 6, 4],
            [10, 8, 7, 12, 3, 9, 5, 14],
            [12, 6, 3, 8, 5, 7, 1, 2],
            [8, 5, 1, 13, 7, 3, 14, 10],
            [9, 2, 5, 1, 13, 6, 2, 8],
            [4, 10, 4, 12, 11, 1, 12, 7],
        ],
        [
            [1, 4, 3, 12, 11, 2, 14, 13],
            [7, 13, 1, 9, 14, 3, 8, 12],
            [4, 5, 3, 7, 13, 9, 12, 14],
            [6, 8, 9, 3, 1, 11, 10, 13],
            [11, 2, 5, 6, 10, 3, 6, 1],
            [10, 7, 14, 8, 3, 4, 5, 6],
            [8, 5, 4, 7, 7, 12, 8, 3],
            [10, 13, 12, 1, 8, 9, 2, 11],
            [1, 9, 14, 10, 6, 11, 7, 2],
            [6, 14, 7, 5, 9, 13, 6, 4],
            [2, 1, 3, 8, 12, 10, 5, 11],
            [10, 7, 4, 6, 2, 8, 1, 10],
        ],
        [
            [9, 8, 3, 4, 11, 1, 2, 13],
            [10, 2, 5, 11, 8, 12, 7, 1],
            [1, 10, 7, 4, 13, 9, 3, 13],
            [3, 5, 13, 9, 2, 1, 4, 10],
            [14, 10, 11, 8, 12, 13, 6, 1],
            [13, 2, 3, 2, 1, 11, 10, 3],
            [7, 4, 2, 14, 14, 3, 5, 2],
            [12, 6, 4, 1, 9, 2, 14, 8],
            [10, 11, 7, 12, 8, 6, 4, 3],
            [5, 8, 6, 13, 1, 9, 4, 14],
            [6, 3, 12, 7, 10, 5, 14, 4],
            [5, 9, 10, 6, 12, 7, 13, 11],
        ],
        [
            [3, 9, 8, 5, 14, 11, 10, 11],
            [12, 1, 2, 6, 7, 13, 3, 5],
            [13, 11, 3, 9, 4, 7, 4, 12],
            [2, 5, 4, 11, 7, 3, 8, 10],
            [1, 13, 5, 2, 1, 9, 6, 7],
            [8, 7, 14, 12, 11, 5, 6, 9],
            [9, 10, 1, 13, 13, 14, 8, 3],
            [10, 6, 4, 7, 12, 1, 11, 12],
            [11, 12, 9, 1, 2, 6, 5, 13],
            [14, 2, 6, 4, 9, 7, 13, 8],
            [11, 1, 13, 10, 3, 4, 12, 2],
            [9, 7, 12, 14, 10, 8, 1, 14],
        ],
    ]
}
