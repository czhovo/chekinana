/*
 * 连连看棋盘生成器
 *
 * 适配微信小程序 / CommonJS。
 * 页面侧：
 *   const { generateBoard, findConnectionPath } = require('./board-generator')
 *
 * 本文件只负责生成可解棋盘，不包含交互和渲染。
 */

'use strict'

var DIRS = [
  { dr: 1, dc: 0 },
  { dr: -1, dc: 0 },
  { dr: 0, dc: 1 },
  { dr: 0, dc: -1 }
]

function generateBoard(options) {
  var normalized = normalizeOptions(options || {})
  if (!normalized.ok) {
    return {
      ok: false,
      board: [],
      pairPositions: [],
      metrics: emptyMetrics(),
      seed: normalized.seed || 0,
      errorCode: 'INVALID_CONFIG'
    }
  }

  var config = normalized.config
  var best = null

  for (var attempt = 0; attempt < config.maxAttempts; attempt++) {
    var attemptSeed = mixSeed(config.seed, attempt + 1)
    var rng = createRng(attemptSeed)

    // 先生成一个按“外层到内层剥洋葱”可消除的 pair 位置序列。
    // 这是 reverse placement 的一个稳定特化：外层先消除，内层随后暴露；
    // 每一层内的每一对在该层完整存在时就已可连，因此后续只会更容易。
    var pairPositions = buildSolvablePairPositions(config, rng)
    if (!pairPositions) continue

    var typeByPairId = assignTypeIds(pairPositions, config, rng)
    var board = materializeBoard(config.rows, config.cols, pairPositions, typeByPairId)

    var validation = validateSolution(board, pairPositions, true)
    if (!validation.ok) continue

    var metrics = calculateMetrics(board, validation.solutionSteps, config)
    var cost = scoreWholeBoard(metrics, config)

    if (!best || cost < best.cost) {
      best = {
        board: board,
        pairPositions: stripPairPositions(pairPositions),
        solutionSteps: validation.solutionSteps,
        metrics: metrics,
        cost: cost
      }
    }

    // 已经足够好则提前返回，避免小程序端卡顿。
    // hard 难度不再只看 difficultyScore；还要约束同一行/列的解法 pair 和开局可消 pair。
    var lineLimit = Math.round(lerp(config.pairCount * 0.58, config.pairCount * 0.28, config.profile.targetDifficulty))
    var availableLineLimit = Math.round(lerp(config.pairCount * 0.38, config.pairCount * 0.18, config.profile.targetDifficulty))
    var adjacentLimit = config.profile.targetDifficulty >= 0.7 ? 2 : 1
    var adjacentGoodEnough = best.metrics.adjacentSameCount <= adjacentLimit
    var lineGoodEnough = (
      best.metrics.sameLineSolutionPairCount <= lineLimit &&
      best.metrics.sameLineAvailableMoveCount <= availableLineLimit
    )
    if (
      adjacentGoodEnough &&
      lineGoodEnough &&
      Math.abs(best.metrics.difficultyScore - config.profile.targetDifficulty) <= 0.28
    ) {
      break
    }
  }

  if (!best) {
    return {
      ok: false,
      board: [],
      pairPositions: [],
      metrics: emptyMetrics(),
      seed: config.seed,
      errorCode: config.ensureSolvable ? 'UNSOLVABLE' : 'GENERATION_TIMEOUT'
    }
  }

  var result = {
    ok: true,
    board: best.board,
    pairPositions: best.pairPositions,
    metrics: best.metrics,
    seed: config.seed
  }
  if (config.returnSolution) result.solutionSteps = best.solutionSteps
  return result
}

/**
 * 对外暴露的连连看路径判定。
 *
 * @param {number[][]} board rows x cols，0 表示空，其余为 typeId
 * @returns {{r:number,c:number}[] | null} 返回压缩后的路径点；不可连接返回 null
 */
function findConnectionPath(board, r1, c1, r2, c2, options) {
  options = options || {}

  if (!board || !board.length || !board[0] || !board[0].length) return null

  var rows = board.length
  var cols = board[0].length

  if (!inBoard(r1, c1, rows, cols) || !inBoard(r2, c2, rows, cols)) return null
  if (r1 === r2 && c1 === c2) return null

  var typeA = board[r1][c1]
  var typeB = board[r2][c2]
  if (!typeA || !typeB || typeA !== typeB) return null

  var rawPath = findPathCore(rows, cols, { r: r1, c: c1 }, { r: r2, c: c2 }, function (r, c) {
    if (!inBoard(r, c, rows, cols)) return false
    if ((r === r1 && c === c1) || (r === r2 && c === c2)) return false
    return board[r][c] !== 0
  })

  if (!rawPath) return null

  var compact = compressPath(rawPath)
  if (countTurns(compact) > 2) return null

  if (options && options.rawPath) return rawPath
  return compact
}

function solveBoard(board, options) {
  options = options || {}

  if (!board || !board.length || !board[0] || !board[0].length) {
    return createSolveResult(false, [], 0, 'INVALID_BOARD', 0)
  }

  var rows = board.length
  var cols = board[0].length
  for (var r = 0; r < rows; r++) {
    if (!board[r] || board[r].length !== cols) {
      return createSolveResult(false, [], 0, 'INVALID_BOARD', 0)
    }
  }

  var working = cloneBoard(board)
  var counts = countTileTypes(working)
  var remainingCells = 0
  for (var type in counts) {
    if (counts[type] % 2 !== 0) {
      return createSolveResult(false, [], 0, 'ODD_TILE_COUNT', 0)
    }
    remainingCells += counts[type]
  }

  if (remainingCells === 0) {
    return createSolveResult(true, [], 0, null, 0)
  }

  var context = {
    startTime: Date.now(),
    maxMs: options.maxMs == null ? 8000 : Math.max(1, toInt(options.maxMs, 8000)),
    maxNodes: options.maxNodes == null ? Infinity : Math.max(1, toInt(options.maxNodes, 500000)),
    sliceMs: options.sliceMs == null ? 1000 : Math.max(1, toInt(options.sliceMs, 1000)),
    nodes: 0,
    memo: Object.create(null),
    timedOut: false,
    nodeLimited: false,
    sliceDeadline: 0,
    sliceTimedOut: false
  }

  var solution = solveBoardProgressive(working, context)
  if (solution) {
    return createSolveResult(true, solution, solution.length, null, context.nodes)
  }

  var errorCode = context.timedOut || context.nodeLimited ? 'SEARCH_LIMIT' : 'NO_SOLUTION'
  return createSolveResult(false, [], remainingCells / 2, errorCode, context.nodes)
}

function createSolveResult(ok, solutionSteps, remainingPairs, errorCode, nodes) {
  return {
    ok: ok,
    solutionSteps: solutionSteps,
    remainingPairs: remainingPairs,
    errorCode: errorCode || '',
    nodes: nodes || 0
  }
}

function solveBoardProgressive(board, context) {
  if (hasSearchLimit(context)) return null
  if (countNonZeroCells(board) === 0) return []

  var previousSliceDeadline = context.sliceDeadline
  var previousSliceTimedOut = context.sliceTimedOut
  var now = Date.now()
  context.sliceDeadline = Math.min(now + context.sliceMs, context.startTime + context.maxMs)
  context.sliceTimedOut = false

  var exactSolution = solveBoardDfs(board, context)
  var sliceTimedOut = context.sliceTimedOut
  context.sliceDeadline = previousSliceDeadline
  context.sliceTimedOut = previousSliceTimedOut

  if (exactSolution) return exactSolution
  if (context.timedOut || context.nodeLimited) return null
  if (!sliceTimedOut) return null

  var moves = collectProgressiveMoves(board)
  if (!moves.length) return null

  for (var i = 0; i < moves.length; i++) {
    if (hasSearchLimit(context)) return null

    var move = moves[i]
    var a = move.a
    var b = move.b
    var typeId = board[a.r][a.c]

    board[a.r][a.c] = 0
    board[b.r][b.c] = 0

    var rest = solveBoardProgressive(board, context)

    board[a.r][a.c] = typeId
    board[b.r][b.c] = typeId

    if (rest) {
      return [{
        a: cloneCell(a),
        b: cloneCell(b),
        typeId: typeId,
        path: clonePath(move.path)
      }].concat(rest)
    }
  }

  return null
}

function collectProgressiveMoves(board) {
  var moves = collectSolvableMoves(board)
  for (var i = 0; i < moves.length; i++) {
    var move = moves[i]
    var a = move.a
    var b = move.b
    var typeId = board[a.r][a.c]

    board[a.r][a.c] = 0
    board[b.r][b.c] = 0
    move.exposedMoveCount = collectSolvableMoves(board).length
    board[a.r][a.c] = typeId
    board[b.r][b.c] = typeId

    move.edgeCellCount = countEdgeCells(board, a, b)
    move.sameLine = a.r === b.r || a.c === b.c
  }

  moves.sort(function (x, y) {
    if (x.exposedMoveCount !== y.exposedMoveCount) return y.exposedMoveCount - x.exposedMoveCount
    if (x.edgeCellCount !== y.edgeCellCount) return y.edgeCellCount - x.edgeCellCount
    if (x.sameLine !== y.sameLine) return x.sameLine ? -1 : 1
    if (x.turns !== y.turns) return x.turns - y.turns
    return y.length - x.length
  })

  return moves
}

function countEdgeCells(board, a, b) {
  var rows = board.length
  var cols = board[0].length
  return (isEdgeCell(a, rows, cols) ? 1 : 0) + (isEdgeCell(b, rows, cols) ? 1 : 0)
}

function isEdgeCell(cell, rows, cols) {
  return cell.r === 0 || cell.c === 0 || cell.r === rows - 1 || cell.c === cols - 1
}

function solveBoardDfs(board, context) {
  if (hasSearchLimit(context)) return null

  context.nodes++

  if (countNonZeroCells(board) === 0) return []

  var key = boardStateKey(board)
  if (context.memo[key]) return null

  var moves = collectSolvableMoves(board)
  if (!moves.length) {
    context.memo[key] = true
    return null
  }

  for (var i = 0; i < moves.length; i++) {
    var move = moves[i]
    var a = move.a
    var b = move.b
    var typeId = board[a.r][a.c]

    board[a.r][a.c] = 0
    board[b.r][b.c] = 0

    var rest = solveBoardDfs(board, context)
    if (rest) {
      board[a.r][a.c] = typeId
      board[b.r][b.c] = typeId
      return [{
        a: cloneCell(a),
        b: cloneCell(b),
        typeId: typeId,
        path: clonePath(move.path)
      }].concat(rest)
    }

    board[a.r][a.c] = typeId
    board[b.r][b.c] = typeId

    if (context.timedOut || context.nodeLimited || context.sliceTimedOut) return null
  }

  context.memo[key] = true
  return null
}

function hasSearchLimit(context) {
  if (context.nodes >= context.maxNodes) {
    context.nodeLimited = true
    return true
  }

  var now = Date.now()
  if (now - context.startTime > context.maxMs) {
    context.timedOut = true
    return true
  }
  if (context.sliceDeadline && now > context.sliceDeadline) {
    context.sliceTimedOut = true
    return true
  }

  return false
}

function collectSolvableMoves(board) {
  var rows = board.length
  var cols = board[0].length
  var cellsByType = Object.create(null)

  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      var type = board[r][c]
      if (!type) continue
      if (!cellsByType[type]) cellsByType[type] = []
      cellsByType[type].push({ r: r, c: c })
    }
  }

  var moves = []
  var moveCountByType = Object.create(null)
  for (var key in cellsByType) {
    var cells = cellsByType[key]
    for (var i = 0; i < cells.length; i++) {
      for (var j = i + 1; j < cells.length; j++) {
        var path = findConnectionPath(board, cells[i].r, cells[i].c, cells[j].r, cells[j].c)
        if (!path) continue
        var move = {
          a: cells[i],
          b: cells[j],
          path: path,
          typeId: board[cells[i].r][cells[i].c],
          turns: countTurns(path),
          length: pathDistance(path)
        }
        moves.push(move)
        moveCountByType[move.typeId] = (moveCountByType[move.typeId] || 0) + 1
      }
    }
  }

  moves.sort(function (x, y) {
    var countDelta = (moveCountByType[x.typeId] || 0) - (moveCountByType[y.typeId] || 0)
    if (countDelta !== 0) return countDelta
    if (x.turns !== y.turns) return y.turns - x.turns
    return y.length - x.length
  })

  return moves
}

function countTileTypes(board) {
  var counts = Object.create(null)
  for (var r = 0; r < board.length; r++) {
    for (var c = 0; c < board[r].length; c++) {
      var type = board[r][c]
      if (!type) continue
      counts[type] = (counts[type] || 0) + 1
    }
  }
  return counts
}

function boardStateKey(board) {
  var parts = []
  for (var r = 0; r < board.length; r++) {
    parts.push(board[r].join(','))
  }
  return parts.join('|')
}

function normalizeOptions(options) {
  var rows = toInt(options.rows, 0)
  var cols = toInt(options.cols, 0)
  var typeCount = toInt(options.typeCount, 0)
  var totalCells = rows * cols
  var pairCount = options.pairCount == null ? totalCells / 2 : toInt(options.pairCount, 0)
  var seed = options.randomSeed == null ? Date.now() : toInt(options.randomSeed, 0)

  if (seed === 0) seed = 1

  if (
    rows <= 0 || cols <= 0 || typeCount <= 0 ||
    totalCells <= 0 || totalCells % 2 !== 0 ||
    pairCount <= 0 || pairCount * 2 > totalCells ||
    pairCount * 2 !== totalCells
  ) {
    // 当前实现按满格棋盘生成；如果未来要支持非满格，可移除 pairCount * 2 !== totalCells 限制。
    return { ok: false, seed: seed }
  }

  var difficultyValue = normalizeDifficulty(options.difficulty)
  var profile = createDifficultyProfile(difficultyValue)

  var maxAttempts = options.maxAttempts == null ? Math.round(lerp(4, 3, difficultyValue)) : Math.max(1, toInt(options.maxAttempts, 4))

  return {
    ok: true,
    config: {
      rows: rows,
      cols: cols,
      typeCount: typeCount,
      pairCount: pairCount,
      totalCells: totalCells,
      difficultyValue: difficultyValue,
      profile: profile,
      avoidAdjacent: options.avoidAdjacent !== false,
      seed: seed >>> 0,
      maxAttempts: maxAttempts,
      maxBacktrack: options.maxBacktrack == null ? profile.backtrackLimit : Math.max(1, toInt(options.maxBacktrack, profile.backtrackLimit)),
      ensureSolvable: options.ensureSolvable !== false,
      returnSolution: options.returnSolution === true
    }
  }
}

function normalizeDifficulty(difficulty) {
  if (typeof difficulty === 'number') return clamp(difficulty, 0, 1)
  if (difficulty === 'easy') return 0.18
  if (difficulty === 'hard') return 0.82
  return 0.5
}

function createDifficultyProfile(d) {
  return {
    targetDifficulty: d,
    adjacencyPenalty: lerp(1200, 900, d),
    turnPenalty: lerp(18, 7, d),
    lengthPenalty: lerp(42, 82, d),
    sameSideBonus: lerp(-10, 2, d),
    branchLimit: Math.round(lerp(10, 18, d)),
    backtrackLimit: Math.round(lerp(2500, 7000, d)),
    randomness: lerp(5, 18, d)
  }
}

function buildSolvablePairPositions(config, rng) {
  // 使用稳定的“外层到内层”构造。它是逆向构造的确定性特化，
  // 生成速度比全局回溯稳定得多，适合小程序端实时生成。
  return buildShellPairPositions(config, rng)
}

function buildShellPairPositions(config, rng) {
  var rows = config.rows
  var cols = config.cols
  var solutionPairs = []
  var layerCount = Math.ceil(Math.min(rows, cols) / 2)

  for (var layer = 0; layer < layerCount; layer++) {
    var rect = {
      top: layer,
      left: layer,
      bottom: rows - 1 - layer,
      right: cols - 1 - layer
    }

    if (rect.top > rect.bottom || rect.left > rect.right) break

    var cells = getLayerCells(rect)
    if (cells.length === 0) continue
    if (cells.length % 2 !== 0) return null

    var stageOccupied = createStageOccupiedGrid(rows, cols, rect)
    var layerPairs = matchLayerPairs(cells, stageOccupied, config, rng, rect)
    if (!layerPairs) return null

    for (var i = 0; i < layerPairs.length; i++) {
      solutionPairs.push(layerPairs[i])
    }
  }

  if (solutionPairs.length !== config.pairCount) return null

  for (var p = 0; p < solutionPairs.length; p++) {
    solutionPairs[p].pairId = p + 1
    // 文档需要 reverseIndex。这里的解题顺序是 P1 -> Pn，反向放入顺序是 Pn -> P1。
    solutionPairs[p].reverseIndex = config.pairCount - 1 - p
  }

  return solutionPairs
}


function buildReverseGreedyPairPositions(config, rng) {
  var occupied = createGrid(config.rows, config.cols, false)
  var reversePairs = []

  for (var reverseIndex = 0; reverseIndex < config.pairCount; reverseIndex++) {
    var candidates = collectReverseCandidates(occupied, config, rng, reverseIndex)
    if (!candidates.length) return null

    var chosen = candidates[0]
    occupied[chosen.a.r][chosen.a.c] = true
    occupied[chosen.b.r][chosen.b.c] = true

    reversePairs.push({
      pairId: 0,
      a: cloneCell(chosen.a),
      b: cloneCell(chosen.b),
      reverseIndex: reverseIndex
    })
  }

  var solutionOrder = reversePairs.slice().reverse()
  for (var i = 0; i < solutionOrder.length; i++) {
    solutionOrder[i].pairId = i + 1
  }
  return solutionOrder
}

function collectReverseCandidates(occupied, config, rng, reverseIndex) {
  var rows = config.rows
  var cols = config.cols
  var empty = collectEmptyCells(occupied, rows, cols)
  if (empty.length < 2) return []

  var totalPairOptions = empty.length * (empty.length - 1) / 2
  var sampleLimit = Math.round(lerp(180, 760, config.difficultyValue)) + reverseIndex * 4
  var exhaustive = empty.length <= 28 || totalPairOptions <= sampleLimit
  var rawPairs = []
  var used = Object.create(null)

  function add(i, j) {
    if (i === j) return
    if (i > j) { var tmp = i; i = j; j = tmp }
    var key = i + ':' + j
    if (used[key]) return
    used[key] = true
    rawPairs.push([i, j])
  }

  if (exhaustive) {
    for (var i = 0; i < empty.length; i++) {
      for (var j = i + 1; j < empty.length; j++) add(i, j)
    }
    shuffleArray(rawPairs, rng)
  } else {
    for (var s = 0; s < sampleLimit; s++) {
      add(randInt(rng, empty.length), randInt(rng, empty.length))
    }
    addReverseStructuredPairs(empty, add, rows, cols, rng)
  }

  var candidates = []
  for (var p = 0; p < rawPairs.length; p++) {
    var a = empty[rawPairs[p][0]]
    var b = empty[rawPairs[p][1]]
    var rawPath = findGenerationPath(occupied, rows, cols, a, b)
    if (!rawPath) continue

    var path = compressPath(rawPath)
    var turns = countTurns(path)
    if (turns > 2) continue
    var length = pathDistance(path)
    var score = scoreReverseCandidate(a, b, path, turns, length, occupied, config, rng)
    candidates.push({ a: a, b: b, score: score, turns: turns, length: length })
  }

  if (!exhaustive && candidates.length === 0) {
    return collectReverseCandidatesExhaustive(occupied, config, rng)
  }

  candidates.sort(function (x, y) { return x.score - y.score })
  return candidates.slice(0, Math.round(lerp(10, 24, config.difficultyValue)))
}

function collectReverseCandidatesExhaustive(occupied, config, rng) {
  var rows = config.rows
  var cols = config.cols
  var empty = collectEmptyCells(occupied, rows, cols)
  var candidates = []

  for (var i = 0; i < empty.length; i++) {
    for (var j = i + 1; j < empty.length; j++) {
      var a = empty[i]
      var b = empty[j]
      var rawPath = findGenerationPath(occupied, rows, cols, a, b)
      if (!rawPath) continue

      var path = compressPath(rawPath)
      var turns = countTurns(path)
      if (turns > 2) continue
      var length = pathDistance(path)
      var score = scoreReverseCandidate(a, b, path, turns, length, occupied, config, rng)
      candidates.push({ a: a, b: b, score: score, turns: turns, length: length })
    }
  }

  candidates.sort(function (x, y) { return x.score - y.score })
  return candidates.slice(0, Math.round(lerp(10, 24, config.difficultyValue)))
}

function addReverseStructuredPairs(empty, addPairByIndex, rows, cols, rng) {
  var byRow = []
  var byCol = []
  for (var r = 0; r < rows; r++) byRow[r] = []
  for (var c = 0; c < cols; c++) byCol[c] = []

  for (var i = 0; i < empty.length; i++) {
    byRow[empty[i].r].push(i)
    byCol[empty[i].c].push(i)
  }

  for (var rr = 0; rr < rows; rr++) addSomePairsFromList(byRow[rr], addPairByIndex, rng, 6)
  for (var cc = 0; cc < cols; cc++) addSomePairsFromList(byCol[cc], addPairByIndex, rng, 6)
}

function addSomePairsFromList(list, addPairByIndex, rng, limit) {
  if (!list || list.length < 2) return
  var tries = Math.min(limit, list.length * 2)
  for (var i = 0; i < tries; i++) {
    addPairByIndex(list[randInt(rng, list.length)], list[randInt(rng, list.length)])
  }
}

function scoreReverseCandidate(a, b, path, turns, length, occupied, config, rng) {
  var d = config.difficultyValue
  var maxDistance = Math.max(1, config.rows + config.cols + 2)
  var score = 0

  if (config.avoidAdjacent && manhattan(a, b) === 1) score += lerp(1200, 900, d)
  if (manhattan(a, b) <= 2) score += lerp(40, 130, d)

  var targetTurns = lerp(0.4, 2, d)
  score += Math.abs(turns - targetTurns) * lerp(28, 35, d)

  var lenNorm = clamp(length / maxDistance, 0, 1)
  var targetLen = lerp(0.12, 0.78, d)
  score += Math.abs(lenNorm - targetLen) * lerp(38, 85, d)

  var maxEdge = Math.max(1, Math.floor(Math.min(config.rows, config.cols) / 2))
  var edgeNorm = clamp((distanceToEdge(a, config.rows, config.cols) + distanceToEdge(b, config.rows, config.cols)) / (2 * maxEdge), 0, 1)
  var targetEdge = lerp(0.05, 0.7, d)
  score += Math.abs(edgeNorm - targetEdge) * lerp(12, 28, d)

  var crowd = occupiedNeighborCount(a, occupied, config.rows, config.cols) + occupiedNeighborCount(b, occupied, config.rows, config.cols)
  var crowdNorm = clamp(crowd / 8, 0, 1)
  var targetCrowd = lerp(0.05, 0.75, d)
  score += Math.abs(crowdNorm - targetCrowd) * lerp(8, 30, d)

  score += rng() * lerp(7, 22, d)
  return score
}

function collectEmptyCells(occupied, rows, cols) {
  var cells = []
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      if (!occupied[r][c]) cells.push({ r: r, c: c })
    }
  }
  return cells
}

function occupiedNeighborCount(cell, occupied, rows, cols) {
  var count = 0
  for (var i = 0; i < DIRS.length; i++) {
    var nr = cell.r + DIRS[i].dr
    var nc = cell.c + DIRS[i].dc
    if (inBoard(nr, nc, rows, cols) && occupied[nr][nc]) count++
  }
  return count
}

function distanceToEdge(cell, rows, cols) {
  return Math.min(cell.r, cell.c, rows - 1 - cell.r, cols - 1 - cell.c)
}

function getLayerCells(rect) {
  var cells = []
  var top = rect.top
  var bottom = rect.bottom
  var left = rect.left
  var right = rect.right

  if (top === bottom) {
    for (var c = left; c <= right; c++) cells.push({ r: top, c: c, side: 'top' })
    return cells
  }

  if (left === right) {
    for (var r = top; r <= bottom; r++) cells.push({ r: r, c: left, side: 'left' })
    return cells
  }

  for (var c1 = left; c1 <= right; c1++) cells.push({ r: top, c: c1, side: 'top' })
  for (var r1 = top + 1; r1 <= bottom - 1; r1++) cells.push({ r: r1, c: right, side: 'right' })
  for (var c2 = right; c2 >= left; c2--) cells.push({ r: bottom, c: c2, side: 'bottom' })
  for (var r2 = bottom - 1; r2 >= top + 1; r2--) cells.push({ r: r2, c: left, side: 'left' })

  return cells
}

function createStageOccupiedGrid(rows, cols, rect) {
  var occupied = createGrid(rows, cols, false)

  // 只把当前层内部的子矩形视为占用。
  // 当前层本身在“层内逆向放置”开始时是空的；
  // 随着 reverse placement 一对一对放回，才逐步变成 occupied。
  // 这比旧版“整层一次性视为占用”更合理：旧版会迫使每一对都只能在同一边消除，
  // 导致 hard 难度也出现大量同一行/同一列的直观可消对。
  for (var r = rect.top + 1; r <= rect.bottom - 1; r++) {
    for (var c = rect.left + 1; c <= rect.right - 1; c++) {
      occupied[r][c] = true
    }
  }

  return occupied
}




function createFullStageOccupiedGrid(rows, cols, rect) {
  var occupied = createGrid(rows, cols, false)
  for (var r = rect.top; r <= rect.bottom; r++) {
    for (var c = rect.left; c <= rect.right; c++) {
      occupied[r][c] = true
    }
  }
  return occupied
}

function trySidePairing(cells, occupied, config, rect) {
  var groups = { top: [], right: [], bottom: [], left: [] }
  for (var i = 0; i < cells.length; i++) groups[cells[i].side].push(cells[i])

  var pairs = []
  var sideNames = ['top', 'right', 'bottom', 'left']

  for (var s = 0; s < sideNames.length; s++) {
    var group = groups[sideNames[s]]
    if (!group.length) continue
    if (group.length % 2 !== 0) return null

    // 长度为 2 的边如果在边内配对一定相邻，交给全层 matching 去跨边处理。
    if (config.avoidAdjacent && group.length === 2) return null

    var indexPairs = buildSideIndexPairs(group.length, config.difficultyValue, config.avoidAdjacent)
    if (!indexPairs) return null

    for (var p = 0; p < indexPairs.length; p++) {
      var a = group[indexPairs[p][0]]
      var b = group[indexPairs[p][1]]
      var rawPath = findGenerationPath(occupied, config.rows, config.cols, a, b)
      if (!rawPath) return null

      var path = compressPath(rawPath)
      if (countTurns(path) > 2) return null

      pairs.push({
        pairId: 0,
        a: cloneCell(a),
        b: cloneCell(b),
        reverseIndex: 0,
        plannedPath: path,
        initialLength: pathDistance(path),
        initialTurns: countTurns(path)
      })
    }
  }

  pairs.sort(function (x, y) {
    var sx = x.initialLength + x.initialTurns * 3
    var sy = y.initialLength + y.initialTurns * 3
    if (config.difficultyValue >= 0.5) return sy - sx
    return sx - sy
  })

  for (var i = 0; i < pairs.length; i++) {
    delete pairs[i].initialLength
    delete pairs[i].initialTurns
  }

  return pairs
}

function buildSideIndexPairs(n, difficultyValue, avoidAdjacent) {
  if (n % 2 !== 0) return null
  if (n === 0) return []

  var targetGap = 2 + Math.max(0, n - 3) * difficultyValue * difficultyValue
  var candidateMap = []
  for (var i = 0; i < n; i++) candidateMap[i] = []

  for (var a = 0; a < n; a++) {
    for (var b = a + 1; b < n; b++) {
      var gap = b - a
      var cost = Math.abs(gap - targetGap) * 10
      if (avoidAdjacent && gap === 1) cost += 1000
      // hard 更偏向极端分离；easy 更偏向局部短配对。
      cost += (1 - difficultyValue) * gap * 0.2
      cost -= difficultyValue * gap * 0.2
      var edge = { a: a, b: b, cost: cost }
      candidateMap[a].push(edge)
      candidateMap[b].push(edge)
    }
  }

  for (var c = 0; c < n; c++) candidateMap[c].sort(function (x, y) { return x.cost - y.cost })

  var used = createArray(n, false)
  var current = []
  var best = null
  var bestCost = Infinity
  var nodes = 0
  var nodeLimit = 12000

  function dfs(matched, cost) {
    nodes++
    if (nodes > nodeLimit) return
    if (cost >= bestCost) return
    if (matched === n) {
      bestCost = cost
      best = current.slice()
      return
    }

    var pick = -1
    var minAvailable = Infinity
    for (var i = 0; i < n; i++) {
      if (used[i]) continue
      var available = 0
      for (var e = 0; e < candidateMap[i].length; e++) {
        var edge = candidateMap[i][e]
        var other = edge.a === i ? edge.b : edge.a
        if (!used[other]) available++
      }
      if (available < minAvailable) {
        minAvailable = available
        pick = i
      }
    }

    if (pick < 0) return

    for (var k = 0; k < candidateMap[pick].length; k++) {
      var chosen = candidateMap[pick][k]
      var otherIndex = chosen.a === pick ? chosen.b : chosen.a
      if (used[pick] || used[otherIndex]) continue

      used[pick] = true
      used[otherIndex] = true
      current.push([pick, otherIndex])
      dfs(matched + 2, cost + chosen.cost)
      current.pop()
      used[pick] = false
      used[otherIndex] = false
    }
  }

  dfs(0, 0)
  return best
}

function tryHardSidePairing(cells, occupied, config, rect) {
  var groups = { top: [], right: [], bottom: [], left: [] }
  for (var i = 0; i < cells.length; i++) groups[cells[i].side].push(cells[i])

  var pairs = []
  var sideNames = ['top', 'right', 'bottom', 'left']

  for (var s = 0; s < sideNames.length; s++) {
    var group = groups[sideNames[s]]
    if (!group.length) continue
    if (group.length % 2 !== 0) return null
    if (config.avoidAdjacent && group.length === 2) return null

    var indexPairs = buildFarIndexPairs(group.length)
    for (var p = 0; p < indexPairs.length; p++) {
      var a = group[indexPairs[p][0]]
      var b = group[indexPairs[p][1]]
      var rawPath = findGenerationPath(occupied, config.rows, config.cols, a, b)
      if (!rawPath) return null
      var path = compressPath(rawPath)
      if (countTurns(path) > 2) return null

      pairs.push({
        pairId: 0,
        a: cloneCell(a),
        b: cloneCell(b),
        reverseIndex: 0,
        plannedPath: path,
        initialLength: pathDistance(path),
        initialTurns: countTurns(path)
      })
    }
  }

  pairs.sort(function (x, y) {
    return (y.initialLength + y.initialTurns * 3) - (x.initialLength + x.initialTurns * 3)
  })

  for (var i = 0; i < pairs.length; i++) {
    delete pairs[i].initialLength
    delete pairs[i].initialTurns
  }

  return pairs
}

function buildFarIndexPairs(n) {
  var result = []
  var left = 0
  var right = n - 1

  while (right - left > 3) {
    result.push([left, right])
    left++
    right--
  }

  if (right - left === 3) {
    result.push([left, left + 2])
    result.push([left + 1, right])
  } else if (right - left === 1) {
    result.push([left, right])
  }

  return result
}

function matchLayerPairs(cells, occupied, config, rng, rect) {
  // 层内使用真正的 reverse placement，而不是旧版的“同边配对”。
  // 生成时从“当前层已被清空、内层仍占用”的状态出发，逆向把 pair 放回当前层。
  // 这样后续解题时：外层先清空；进入本层后，少量同边 pair 先打开缺口，随后大量跨边/折线路径 pair 才能被消除。
  // 结果仍然可解，但不会把整层全部做成同一行/同一列的 pair。
  var best = null
  var attempts = Math.round(lerp(5, 9, config.difficultyValue))

  for (var attempt = 0; attempt < attempts; attempt++) {
    var work = cloneBoolGrid(occupied)
    var built = buildLayerReversePlacement(cells, work, config, rng, rect, attempt)
    if (!built) continue

    var quality = scoreLayerPairSet(built, config)
    if (!best || quality < best.quality) {
      best = { pairs: built, quality: quality }
      if (quality <= config.difficultyValue * 2) break
    }
  }

  if (best) return best.pairs

  // 兜底：极端 seed 下层内逆向生成可能失败。
  // 此时退回旧的同边剥层配对，保证 generateBoard 不轻易返回 UNSOLVABLE。
  // hard 下正常不会走到这里；如果走到这里，整体评分会因 sameLine 指标变差而在外层重试中被淘汰。
  var fallbackOccupied = createFullStageOccupiedGrid(config.rows, config.cols, rect)
  return trySidePairing(cells, fallbackOccupied, config, rect)
}


function buildLayerReversePlacement(cells, occupied, config, rng, rect, attemptIndex) {
  var pairTarget = cells.length / 2
  if (cells.length % 2 !== 0) return null

  var reversePairs = []
  var branchBase = Math.round(lerp(4, 12, config.difficultyValue))

  for (var depth = 0; depth < pairTarget; depth++) {
    var candidates = collectLayerReverseCandidates(cells, occupied, config, rng, rect, depth, attemptIndex)
    if (!candidates.length) return null

    var chooseLimit = Math.min(candidates.length, branchBase + Math.floor(attemptIndex / 3))
    var chosenIndex = pickWeightedCandidateIndex(candidates, chooseLimit, rng, config.difficultyValue)
    var chosen = candidates[chosenIndex]

    occupied[chosen.a.r][chosen.a.c] = true
    occupied[chosen.b.r][chosen.b.c] = true
    reversePairs.push({
      pairId: 0,
      a: cloneCell(chosen.a),
      b: cloneCell(chosen.b),
      reverseIndex: depth,
      plannedPath: chosen.path,
      initialTurns: chosen.turns,
      initialLength: chosen.length,
      sameLine: chosen.sameLine
    })
  }

  // reversePairs 是逆向放回顺序；真正解题顺序要反过来。
  var solutionPairs = reversePairs.slice().reverse()
  for (var p = 0; p < solutionPairs.length; p++) {
    delete solutionPairs[p].initialTurns
    delete solutionPairs[p].initialLength
    delete solutionPairs[p].sameLine
  }
  return solutionPairs
}


function pickWeightedCandidateIndex(candidates, limit, rng, difficultyValue) {
  if (limit <= 1) return 0
  var temperature = lerp(1.8, 4.8, difficultyValue)
  var weights = []
  var total = 0
  var best = candidates[0].score
  for (var i = 0; i < limit; i++) {
    var w = Math.exp(-(candidates[i].score - best) / Math.max(1, temperature))
    weights.push(w)
    total += w
  }
  var roll = rng() * total
  for (var j = 0; j < limit; j++) {
    roll -= weights[j]
    if (roll <= 0) return j
  }
  return limit - 1
}

function collectLayerReverseCandidates(cells, occupied, config, rng, rect, reverseDepth, attemptIndex) {
  var empty = []
  for (var i = 0; i < cells.length; i++) {
    if (!occupied[cells[i].r][cells[i].c]) empty.push(cells[i])
  }
  if (empty.length < 2) return []

  var candidates = []
  for (var aIndex = 0; aIndex < empty.length; aIndex++) {
    for (var bIndex = aIndex + 1; bIndex < empty.length; bIndex++) {
      var a = empty[aIndex]
      var b = empty[bIndex]
      var rawPath = findGenerationPath(occupied, config.rows, config.cols, a, b)
      if (!rawPath) continue

      var path = compressPath(rawPath)
      var turns = countTurns(path)
      if (turns > 2) continue

      var length = pathDistance(path)
      var sameLine = a.r === b.r || a.c === b.c
      var score = scoreLayerReverseCandidate(a, b, path, turns, length, sameLine, occupied, config, rng, rect, reverseDepth, attemptIndex)
      candidates.push({ a: a, b: b, path: path, turns: turns, length: length, sameLine: sameLine, score: score })
    }
  }

  if (config.avoidAdjacent) {
    var nonAdjacent = []
    for (var na = 0; na < candidates.length; na++) {
      if (manhattan(candidates[na].a, candidates[na].b) !== 1) nonAdjacent.push(candidates[na])
    }
    if (nonAdjacent.length) candidates = nonAdjacent
  }

  // hard 模式进一步过滤同一行/列候选。
  // 只要存在非同线候选，就不选同线；当局面确实只能靠同线 pair 打开缺口时才允许。
  if (config.difficultyValue >= 0.65) {
    var nonSameLine = []
    for (var ns = 0; ns < candidates.length; ns++) {
      if (!candidates[ns].sameLine) nonSameLine.push(candidates[ns])
    }
    if (nonSameLine.length) candidates = nonSameLine
  }

  candidates.sort(function (x, y) { return x.score - y.score })
  return candidates
}

function scoreLayerReverseCandidate(a, b, path, turns, length, sameLine, occupied, config, rng, rect, reverseDepth, attemptIndex) {
  var d = config.difficultyValue
  var maxDistance = Math.max(1, config.rows + config.cols + 2)
  var pairDistance = manhattan(a, b)
  var score = 0

  if (config.avoidAdjacent && pairDistance === 1) score += lerp(4000, 8000, d)
  if (pairDistance <= 2) score += lerp(30, 180, d)

  // 这是本版最关键的修正：hard 强烈惩罚同一行/同一列的 pair。
  // 注意不是完全禁止，因为满格开局和极小内层仍然需要少量同边 pair 打开缺口。
  if (sameLine) score += lerp(8, 520, d)

  var sameSide = a.side && b.side && a.side === b.side
  if (sameSide) score += lerp(-8, 180, d)
  else score -= lerp(0, 80, d)

  // hard 偏向 2 拐和更长路径；easy 偏向短路径和较少拐弯。
  var targetTurns = lerp(0.6, 2.0, d)
  score += Math.abs(turns - targetTurns) * lerp(18, 55, d)

  var lenNorm = clamp(length / maxDistance, 0, 1)
  var targetLen = lerp(0.16, 0.82, d)
  score += Math.abs(lenNorm - targetLen) * lerp(35, 110, d)

  // 逆向越靠后，越接近玩家开局；这些 pair 通常必须更简单。
  // 因此 hard 不强行压死开局必需的少量同边 pair，只在整体评分里继续压数量。
  var fillRatio = reverseDepth / Math.max(1, cellsOnLayer(rect) / 2 - 1)
  if (fillRatio > 0.72 && sameLine) score -= lerp(0, 160, d)

  var crowd = occupiedNeighborCount(a, occupied, config.rows, config.cols) + occupiedNeighborCount(b, occupied, config.rows, config.cols)
  var targetCrowd = lerp(0.1, 0.65, d) * 8
  score += Math.abs(crowd - targetCrowd) * lerp(3, 14, d)

  score += rng() * lerp(4, 24, d)
  return score
}

function diversifyCandidatePrefix(candidates, limit, rng, difficultyValue) {
  var take = Math.min(candidates.length, Math.max(limit * 3, limit + 2))
  var prefix = candidates.slice(0, take)
  for (var i = 0; i < prefix.length; i++) {
    prefix[i] = cloneCandidateWithScore(prefix[i], prefix[i].score + rng() * lerp(2, 18, difficultyValue))
  }
  prefix.sort(function (x, y) { return x.score - y.score })
  return prefix.concat(candidates.slice(take))
}

function cloneCandidateWithScore(candidate, score) {
  return {
    a: candidate.a,
    b: candidate.b,
    path: candidate.path,
    turns: candidate.turns,
    length: candidate.length,
    sameLine: candidate.sameLine,
    score: score
  }
}

function scoreLayerPairSet(pairs, config) {
  var sameLine = 0
  var adjacent = 0
  var turnSum = 0
  var lenSum = 0
  for (var i = 0; i < pairs.length; i++) {
    var p = pairs[i]
    if (p.a.r === p.b.r || p.a.c === p.b.c) sameLine++
    if (manhattan(p.a, p.b) === 1) adjacent++
    turnSum += p.initialTurns || countTurns(p.plannedPath)
    lenSum += p.initialLength || pathDistance(p.plannedPath)
  }
  var avgTurns = pairs.length ? turnSum / pairs.length : 0
  var avgLength = pairs.length ? lenSum / pairs.length : 0
  var d = config.difficultyValue

  return sameLine * lerp(18, 220, d) + adjacent * 1000 - avgTurns * lerp(2, 28, d) - avgLength * lerp(0.2, 4.5, d)
}

function cellsOnLayer(rect) {
  if (rect.top > rect.bottom || rect.left > rect.right) return 0
  if (rect.top === rect.bottom) return rect.right - rect.left + 1
  if (rect.left === rect.right) return rect.bottom - rect.top + 1
  return (rect.right - rect.left + 1) * 2 + (rect.bottom - rect.top - 1) * 2
}

function cloneBoolGrid(grid) {
  var copy = []
  for (var r = 0; r < grid.length; r++) copy.push(grid[r].slice())
  return copy
}


function scoreLayerCandidate(a, b, path, turns, length, config, rng, rect) {
  var d = config.difficultyValue
  var profile = config.profile
  var maxDistance = Math.max(1, config.rows + config.cols + 2)
  var score = 0

  if (config.avoidAdjacent && manhattan(a, b) === 1) {
    score += profile.adjacencyPenalty
  }

  // easy 偏短，hard 偏长。
  var lenNorm = clamp(length / maxDistance, 0, 1)
  var targetLen = 0.12 + 0.50 * d * d
  score += Math.abs(lenNorm - targetLen) * profile.lengthPenalty

  // easy 不强求 2 拐；hard 更接受 2 拐。
  var targetTurns = lerp(0.8, 2, d)
  score += Math.abs(turns - targetTurns) * profile.turnPenalty

  var sameSide = a.side === b.side
  if (sameSide) {
    score += profile.sameSideBonus
  } else {
    // easy 不鼓励跨边；hard 基本中性，主要由路径长度决定。
    score -= profile.sameSideBonus * 0.6
  }

  // hard 倾向更长路径；easy 倾向更短、更靠同边的路径。
  var cornerDistance = distanceToNearestLayerCorner(a, rect) + distanceToNearestLayerCorner(b, rect)
  var cornerNorm = clamp(cornerDistance / Math.max(1, config.rows + config.cols), 0, 1)
  var targetCorner = lerp(0.28, 0.08, d)
  score += Math.abs(cornerNorm - targetCorner) * lerp(8, 16, d)

  score += rng() * profile.randomness
  return score
}

function distanceToNearestLayerCorner(cell, rect) {
  var corners = [
    { r: rect.top, c: rect.left },
    { r: rect.top, c: rect.right },
    { r: rect.bottom, c: rect.left },
    { r: rect.bottom, c: rect.right }
  ]
  var best = Infinity
  for (var i = 0; i < corners.length; i++) {
    best = Math.min(best, Math.abs(cell.r - corners[i].r) + Math.abs(cell.c - corners[i].c))
  }
  return best
}

function findGenerationPath(occupied, rows, cols, a, b) {
  return findPathCore(rows, cols, a, b, function (r, c) {
    if (!inBoard(r, c, rows, cols)) return false
    if ((r === a.r && c === a.c) || (r === b.r && c === b.c)) return false
    return occupied[r][c]
  })
}

function findPathCore(rows, cols, start, end, isBlocked) {
  // 连连看最多 2 拐，可以直接枚举 0/1/2 拐路径；比 BFS 复制 path 快很多。
  var p0 = { r: start.r, c: start.c }
  var p3 = { r: end.r, c: end.c }

  if (isStraightClear(p0, p3, rows, cols, isBlocked)) {
    return [p0, p3]
  }

  var p1 = { r: start.r, c: end.c }
  if (inExpandedBoard(p1.r, p1.c, rows, cols) &&
      isStraightClear(p0, p1, rows, cols, isBlocked) &&
      isStraightClear(p1, p3, rows, cols, isBlocked)) {
    return compressPath([p0, p1, p3])
  }

  var p2 = { r: end.r, c: start.c }
  if (inExpandedBoard(p2.r, p2.c, rows, cols) &&
      isStraightClear(p0, p2, rows, cols, isBlocked) &&
      isStraightClear(p2, p3, rows, cols, isBlocked)) {
    return compressPath([p0, p2, p3])
  }

  var bestRowPath = null
  var bestRowScore = Infinity
  var midRow = (start.r + end.r) * 0.5

  for (var r = -1; r <= rows; r++) {
    var a = { r: r, c: start.c }
    var b = { r: r, c: end.c }
    if (!inExpandedBoard(a.r, a.c, rows, cols) || !inExpandedBoard(b.r, b.c, rows, cols)) continue
    if (isStraightClear(p0, a, rows, cols, isBlocked) &&
        isStraightClear(a, b, rows, cols, isBlocked) &&
        isStraightClear(b, p3, rows, cols, isBlocked)) {
      var boundaryPenalty = (r === -1 || r === rows) ? 500 : 0
      var segmentScore = Math.abs(r - start.r) + Math.abs(end.r - r) + Math.abs(start.c - end.c) + boundaryPenalty + Math.abs(r - midRow)
      if (segmentScore < bestRowScore) {
        bestRowScore = segmentScore
        bestRowPath = [p0, a, b, p3]
      }
    }
  }

  if (bestRowPath) return compressPath(bestRowPath)

  var bestColPath = null
  var bestColScore = Infinity
  var midCol = (start.c + end.c) * 0.5

  for (var c = -1; c <= cols; c++) {
    var c1 = { r: start.r, c: c }
    var c2 = { r: end.r, c: c }
    if (!inExpandedBoard(c1.r, c1.c, rows, cols) || !inExpandedBoard(c2.r, c2.c, rows, cols)) continue
    if (isStraightClear(p0, c1, rows, cols, isBlocked) &&
        isStraightClear(c1, c2, rows, cols, isBlocked) &&
        isStraightClear(c2, p3, rows, cols, isBlocked)) {
      var boundaryPenalty = (c === -1 || c === cols) ? 500 : 0
      var segmentScore = Math.abs(c - start.c) + Math.abs(end.c - c) + Math.abs(start.r - end.r) + boundaryPenalty + Math.abs(c - midCol)
      if (segmentScore < bestColScore) {
        bestColScore = segmentScore
        bestColPath = [p0, c1, c2, p3]
      }
    }
  }

  if (bestColPath) return compressPath(bestColPath)

  return null
}

function isStraightClear(a, b, rows, cols, isBlocked) {
  if (a.r !== b.r && a.c !== b.c) return false
  if (!inExpandedBoard(a.r, a.c, rows, cols) || !inExpandedBoard(b.r, b.c, rows, cols)) return false

  var dr = sign(b.r - a.r)
  var dc = sign(b.c - a.c)
  var r = a.r
  var c = a.c

  while (r !== b.r || c !== b.c) {
    r += dr
    c += dc
    if (!inExpandedBoard(r, c, rows, cols)) return false
    if (isBlocked(r, c)) return false
  }

  return true
}

function assignTypeIds(pairPositions, config, rng) {
  var pairCount = pairPositions.length
  var typeCount = config.typeCount
  var graph = buildPairAdjacencyGraph(pairPositions, config.rows, config.cols)
  var quotas = buildTypeQuotas(pairCount, typeCount, rng)
  var used = createArray(typeCount + 1, 0)
  var typeByPairId = Object.create(null)

  var order = []
  for (var i = 0; i < pairCount; i++) order.push(i)
  order.sort(function (ia, ib) { return graph[ib].length - graph[ia].length })

  for (var oi = 0; oi < order.length; oi++) {
    var pairIndex = order[oi]
    var pairId = pairPositions[pairIndex].pairId
    var bestType = 1
    var bestCost = Infinity

    for (var t = 1; t <= typeCount; t++) {
      if (used[t] >= quotas[t]) continue

      var cost = 0
      var neighbors = graph[pairIndex]
      for (var n = 0; n < neighbors.length; n++) {
        var neighborPair = pairPositions[neighbors[n]]
        if (typeByPairId[neighborPair.pairId] === t) cost += 1000
      }

      // 二阶邻居轻微惩罚，减少同图案扎堆。
      for (var n2 = 0; n2 < neighbors.length; n2++) {
        var secondNeighbors = graph[neighbors[n2]]
        for (var s = 0; s < secondNeighbors.length; s++) {
          var secondPair = pairPositions[secondNeighbors[s]]
          if (typeByPairId[secondPair.pairId] === t) cost += 18
        }
      }

      // hard 难度下进一步避免同 type 出现在同一行/列。
      // 这不是连通判定的必要条件，但直接影响玩家视觉上“同一行/列一眼可消”的体感。
      cost += estimateTypeLineConflict(pairPositions[pairIndex], t, pairPositions, typeByPairId, config)

      cost += (used[t] / Math.max(1, quotas[t])) * 8
      cost += rng() * 4

      if (cost < bestCost) {
        bestCost = cost
        bestType = t
      }
    }

    typeByPairId[pairId] = bestType
    used[bestType]++
  }

  optimizeTypeAssignment(pairPositions, graph, typeByPairId, rng, config)
  return typeByPairId
}

function buildTypeQuotas(pairCount, typeCount, rng) {
  var quotas = createArray(typeCount + 1, 0)
  var base = Math.floor(pairCount / typeCount)
  var rest = pairCount % typeCount
  var types = []

  for (var t = 1; t <= typeCount; t++) {
    quotas[t] = base
    types.push(t)
  }

  shuffleArray(types, rng)
  for (var i = 0; i < rest; i++) quotas[types[i]]++
  return quotas
}

function buildPairAdjacencyGraph(pairPositions, rows, cols) {
  var indexByCell = Object.create(null)
  var graph = []

  for (var i = 0; i < pairPositions.length; i++) {
    graph[i] = []
    indexByCell[cellKey(pairPositions[i].a.r, pairPositions[i].a.c)] = i
    indexByCell[cellKey(pairPositions[i].b.r, pairPositions[i].b.c)] = i
  }

  var edgeSet = Object.create(null)

  for (var p = 0; p < pairPositions.length; p++) {
    var cells = [pairPositions[p].a, pairPositions[p].b]
    for (var ci = 0; ci < cells.length; ci++) {
      var cell = cells[ci]
      for (var d = 0; d < DIRS.length; d++) {
        var nr = cell.r + DIRS[d].dr
        var nc = cell.c + DIRS[d].dc
        if (!inBoard(nr, nc, rows, cols)) continue

        var other = indexByCell[cellKey(nr, nc)]
        if (other == null || other === p) continue

        var x = Math.min(p, other)
        var y = Math.max(p, other)
        var key = x + ':' + y
        if (edgeSet[key]) continue
        edgeSet[key] = true
        graph[x].push(y)
        graph[y].push(x)
      }
    }
  }

  return graph
}


function estimateTypeLineConflict(pair, typeId, pairPositions, typeByPairId, config) {
  var cost = 0
  var d = config.difficultyValue
  var cells = [pair.a, pair.b]

  // pair 自身同一行/列时，它天然形成“同图同线”，hard 下应当很贵。
  if (pair.a.r === pair.b.r || pair.a.c === pair.b.c) cost += lerp(8, 160, d)

  for (var i = 0; i < pairPositions.length; i++) {
    var other = pairPositions[i]
    if (typeByPairId[other.pairId] !== typeId) continue
    var otherCells = [other.a, other.b]
    for (var a = 0; a < cells.length; a++) {
      for (var b = 0; b < otherCells.length; b++) {
        if (cells[a].r === otherCells[b].r || cells[a].c === otherCells[b].c) cost += lerp(10, 95, d)
        var md = manhattan(cells[a], otherCells[b])
        if (md === 1) cost += 1000
        else if (md === 2) cost += lerp(8, 35, d)
      }
    }
  }

  return cost
}

function calculateTypeAssignmentCost(pairPositions, graph, typeByPairId, config) {
  var cost = countPairGraphSameTypeEdges(pairPositions, graph, typeByPairId) * 1000
  var d = config.difficultyValue

  for (var i = 0; i < pairPositions.length; i++) {
    var p = pairPositions[i]
    var typeP = typeByPairId[p.pairId]
    if (p.a.r === p.b.r || p.a.c === p.b.c) cost += lerp(1, 35, d)

    for (var j = i + 1; j < pairPositions.length; j++) {
      var q = pairPositions[j]
      if (typeByPairId[q.pairId] !== typeP) continue
      var pc = [p.a, p.b]
      var qc = [q.a, q.b]
      for (var a = 0; a < pc.length; a++) {
        for (var b = 0; b < qc.length; b++) {
          if (pc[a].r === qc[b].r || pc[a].c === qc[b].c) cost += lerp(4, 60, d)
          var md = manhattan(pc[a], qc[b])
          if (md === 1) cost += 1000
          else if (md === 2) cost += lerp(5, 24, d)
        }
      }
    }
  }

  return cost
}

function optimizeTypeAssignment(pairPositions, graph, typeByPairId, rng, config) {
  var iterations = pairPositions.length * 24
  var current = calculateTypeAssignmentCost(pairPositions, graph, typeByPairId, config)

  for (var i = 0; i < iterations && current > 0; i++) {
    var aIndex = randInt(rng, pairPositions.length)
    var bIndex = randInt(rng, pairPositions.length)
    if (aIndex === bIndex) continue

    var aPair = pairPositions[aIndex]
    var bPair = pairPositions[bIndex]
    var typeA = typeByPairId[aPair.pairId]
    var typeB = typeByPairId[bPair.pairId]
    if (typeA === typeB) continue

    typeByPairId[aPair.pairId] = typeB
    typeByPairId[bPair.pairId] = typeA

    var next = calculateTypeAssignmentCost(pairPositions, graph, typeByPairId, config)
    if (next <= current || rng() < 0.02) {
      current = next
    } else {
      typeByPairId[aPair.pairId] = typeA
      typeByPairId[bPair.pairId] = typeB
    }
  }
}

function materializeBoard(rows, cols, pairPositions, typeByPairId) {
  var board = createGrid(rows, cols, 0)

  for (var i = 0; i < pairPositions.length; i++) {
    var pair = pairPositions[i]
    var typeId = typeByPairId[pair.pairId]
    board[pair.a.r][pair.a.c] = typeId
    board[pair.b.r][pair.b.c] = typeId
  }

  return board
}

function validateSolution(board, pairPositions, returnSolution) {
  var working = cloneBoard(board)
  var steps = []

  for (var i = 0; i < pairPositions.length; i++) {
    var pair = pairPositions[i]
    var a = pair.a
    var b = pair.b
    var typeA = working[a.r][a.c]
    var typeB = working[b.r][b.c]

    if (!typeA || typeA !== typeB) return { ok: false, solutionSteps: [] }

    var foundPath = findConnectionPath(working, a.r, a.c, b.r, b.c)
    if (!foundPath) return { ok: false, solutionSteps: [] }

    var path = foundPath
    if (pair.plannedPath && isUsableConnectionPath(working, pair.plannedPath, a, b)) {
      path = pair.plannedPath
    }

    if (returnSolution) {
      steps.push({ pairId: pair.pairId, a: cloneCell(a), b: cloneCell(b), typeId: typeA, path: clonePath(path) })
    }

    working[a.r][a.c] = 0
    working[b.r][b.c] = 0
  }

  if (countNonZeroCells(working) !== 0) return { ok: false, solutionSteps: [] }
  return { ok: true, solutionSteps: steps }
}


function stripPairPositions(pairPositions) {
  var result = []
  for (var i = 0; i < pairPositions.length; i++) {
    result.push({
      pairId: pairPositions[i].pairId,
      a: cloneCell(pairPositions[i].a),
      b: cloneCell(pairPositions[i].b),
      reverseIndex: pairPositions[i].reverseIndex
    })
  }
  return result
}

function clonePath(path) {
  var result = []
  for (var i = 0; i < path.length; i++) result.push(cloneCell(path[i]))
  return result
}

function isUsableConnectionPath(board, path, a, b) {
  if (!path || path.length < 2) return false
  if (path[0].r !== a.r || path[0].c !== a.c) return false
  var last = path[path.length - 1]
  if (last.r !== b.r || last.c !== b.c) return false
  if (countTurns(path) > 2) return false

  var rows = board.length
  var cols = board[0].length

  for (var i = 1; i < path.length; i++) {
    var prev = path[i - 1]
    var cur = path[i]
    var dr = sign(cur.r - prev.r)
    var dc = sign(cur.c - prev.c)

    if (dr !== 0 && dc !== 0) return false
    if (dr === 0 && dc === 0) return false

    var r = prev.r
    var c = prev.c
    while (r !== cur.r || c !== cur.c) {
      r += dr
      c += dc
      if (!inExpandedBoard(r, c, rows, cols)) return false
      if (!inBoard(r, c, rows, cols)) continue
      if ((r === a.r && c === a.c) || (r === b.r && c === b.c)) continue
      if (board[r][c] !== 0) return false
    }
  }

  return true
}

function calculateMetrics(board, solutionSteps, config) {
  var adjacentSameCount = countAdjacentSameCells(board)
  var averagePathTurns = 0
  var averagePathLength = 0

  if (solutionSteps && solutionSteps.length) {
    var turnSum = 0
    var lengthSum = 0
    var weightSum = 0
    for (var i = 0; i < solutionSteps.length; i++) {
      var path = solutionSteps[i].path || []
      // 初始阶段对体感难度影响更大，所以质量指标对前半段消除加权更高。
      var weight = solutionSteps.length - i
      turnSum += countTurns(path) * weight
      lengthSum += pathDistance(path) * weight
      weightSum += weight
    }
    averagePathTurns = turnSum / weightSum
    averagePathLength = lengthSum / weightSum
  }

  var availableMoveInfo = countAvailableMoveInfo(board)
  var availableMoveCount = availableMoveInfo.total
  var sameLineSolutionPairCount = countSameLineSolutionPairs(solutionSteps)
  var difficultyScore = calculateDifficultyScore({
    adjacentSameCount: adjacentSameCount,
    averagePathTurns: averagePathTurns,
    averagePathLength: averagePathLength,
    availableMoveCount: availableMoveCount,
    sameLineSolutionPairCount: sameLineSolutionPairCount,
    sameLineAvailableMoveCount: availableMoveInfo.sameLine,
    zeroTurnAvailableMoveCount: availableMoveInfo.zeroTurn
  }, config)

  return {
    adjacentSameCount: adjacentSameCount,
    averagePathTurns: round2(averagePathTurns),
    averagePathLength: round2(averagePathLength),
    availableMoveCount: availableMoveCount,
    sameLineSolutionPairCount: sameLineSolutionPairCount,
    sameLineAvailableMoveCount: availableMoveInfo.sameLine,
    zeroTurnAvailableMoveCount: availableMoveInfo.zeroTurn,
    difficultyScore: round2(difficultyScore)
  }
}

function calculateDifficultyScore(metrics, config) {
  var turnScore = clamp(metrics.averagePathTurns / 2, 0, 1)
  var lenScore = clamp((metrics.averagePathLength - 3) / Math.max(1, Math.min(config.rows, config.cols)), 0, 1)
  var moveLooseLimit = Math.max(1, config.pairCount * 0.35)
  var availabilityScore = 1 - clamp((metrics.availableMoveCount - 1) / moveLooseLimit, 0, 1)

  var sameLineSolutionPenalty = clamp(metrics.sameLineSolutionPairCount / Math.max(1, config.pairCount), 0, 1)
  var sameLineAvailablePenalty = clamp(metrics.sameLineAvailableMoveCount / Math.max(1, config.pairCount * 0.35), 0, 1)
  var zeroTurnPenalty = clamp(metrics.zeroTurnAvailableMoveCount / Math.max(1, config.pairCount * 0.2), 0, 1)

  var raw = clamp(
    turnScore * 0.35 +
    lenScore * 0.43 +
    availabilityScore * 0.22 -
    sameLineSolutionPenalty * 0.20 -
    sameLineAvailablePenalty * 0.18 -
    zeroTurnPenalty * 0.10,
    0,
    1
  )

  return clamp((raw - 0.30) / 0.30, 0, 1)
}

function scoreWholeBoard(metrics, config) {
  var target = config.profile.targetDifficulty
  var difficultyDelta = Math.abs(metrics.difficultyScore - target)
  var lineWeight = lerp(12, 260, target)
  return (
    metrics.adjacentSameCount * 1000 +
    metrics.sameLineSolutionPairCount * lineWeight +
    metrics.sameLineAvailableMoveCount * lineWeight * 1.4 +
    metrics.zeroTurnAvailableMoveCount * lineWeight * 0.9 +
    difficultyDelta * 220 +
    Math.abs(metrics.averagePathLength - lerp(4, config.rows + config.cols, target))
  )
}

function countAvailableMoves(board) {
  return countAvailableMoveInfo(board).total
}

function countAvailableMoveInfo(board) {
  var rows = board.length
  var cols = board[0].length
  var cellsByType = Object.create(null)
  var info = { total: 0, sameLine: 0, zeroTurn: 0 }

  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      var type = board[r][c]
      if (!type) continue
      if (!cellsByType[type]) cellsByType[type] = []
      cellsByType[type].push({ r: r, c: c })
    }
  }

  for (var key in cellsByType) {
    var cells = cellsByType[key]
    for (var i = 0; i < cells.length; i++) {
      for (var j = i + 1; j < cells.length; j++) {
        var path = findConnectionPath(board, cells[i].r, cells[i].c, cells[j].r, cells[j].c)
        if (!path) continue
        info.total++
        if (cells[i].r === cells[j].r || cells[i].c === cells[j].c) info.sameLine++
        if (countTurns(path) === 0) info.zeroTurn++
      }
    }
  }

  return info
}

function countSameLineSolutionPairs(solutionSteps) {
  if (!solutionSteps || !solutionSteps.length) return 0
  var count = 0
  for (var i = 0; i < solutionSteps.length; i++) {
    if (solutionSteps[i].a.r === solutionSteps[i].b.r || solutionSteps[i].a.c === solutionSteps[i].b.c) count++
  }
  return count
}

function countAdjacentSameCells(board) {
  var rows = board.length
  var cols = board[0].length
  var count = 0

  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      var type = board[r][c]
      if (!type) continue
      if (r + 1 < rows && board[r + 1][c] === type) count++
      if (c + 1 < cols && board[r][c + 1] === type) count++
    }
  }

  return count
}

function countPairGraphSameTypeEdges(pairPositions, graph, typeByPairId) {
  var count = 0
  for (var i = 0; i < graph.length; i++) {
    var typeI = typeByPairId[pairPositions[i].pairId]
    for (var j = 0; j < graph[i].length; j++) {
      var other = graph[i][j]
      if (other <= i) continue
      if (typeByPairId[pairPositions[other].pairId] === typeI) count++
    }
  }
  return count
}

function countNonZeroCells(board) {
  var count = 0
  for (var r = 0; r < board.length; r++) {
    for (var c = 0; c < board[r].length; c++) {
      if (board[r][c] !== 0) count++
    }
  }
  return count
}

function compressPath(path) {
  if (!path || path.length <= 2) return path ? path.slice() : []

  var compact = [cloneCell(path[0])]

  for (var i = 1; i < path.length - 1; i++) {
    var prev = path[i - 1]
    var cur = path[i]
    var next = path[i + 1]

    var d1r = sign(cur.r - prev.r)
    var d1c = sign(cur.c - prev.c)
    var d2r = sign(next.r - cur.r)
    var d2c = sign(next.c - cur.c)

    if (d1r !== d2r || d1c !== d2c) compact.push(cloneCell(cur))
  }

  compact.push(cloneCell(path[path.length - 1]))
  return compact
}

function countTurns(path) {
  if (!path || path.length < 3) return 0
  var turns = 0

  for (var i = 1; i < path.length - 1; i++) {
    var prev = path[i - 1]
    var cur = path[i]
    var next = path[i + 1]

    var d1r = sign(cur.r - prev.r)
    var d1c = sign(cur.c - prev.c)
    var d2r = sign(next.r - cur.r)
    var d2c = sign(next.c - cur.c)

    if (d1r !== d2r || d1c !== d2c) turns++
  }

  return turns
}

function pathDistance(path) {
  if (!path || path.length < 2) return 0
  var dist = 0
  for (var i = 1; i < path.length; i++) {
    dist += Math.abs(path[i].r - path[i - 1].r) + Math.abs(path[i].c - path[i - 1].c)
  }
  return dist
}

function createGrid(rows, cols, value) {
  var grid = []
  for (var r = 0; r < rows; r++) {
    var row = []
    for (var c = 0; c < cols; c++) row.push(value)
    grid.push(row)
  }
  return grid
}

function createArray(length, value) {
  var arr = []
  for (var i = 0; i < length; i++) arr.push(value)
  return arr
}

function cloneBoard(board) {
  var copy = []
  for (var r = 0; r < board.length; r++) copy.push(board[r].slice())
  return copy
}

function cloneCell(cell) {
  return { r: cell.r, c: cell.c }
}

function inBoard(r, c, rows, cols) {
  return r >= 0 && r < rows && c >= 0 && c < cols
}

function inExpandedBoard(r, c, rows, cols) {
  return r >= -1 && r <= rows && c >= -1 && c <= cols
}

function cellKey(r, c) {
  return r + ',' + c
}

function manhattan(a, b) {
  return Math.abs(a.r - b.r) + Math.abs(a.c - b.c)
}

function clamp(value, min, max) {
  if (value < min) return min
  if (value > max) return max
  return value
}

function lerp(a, b, t) {
  return a + (b - a) * t
}

function sign(value) {
  if (value > 0) return 1
  if (value < 0) return -1
  return 0
}

function toInt(value, fallback) {
  var n = parseInt(value, 10)
  return isNaN(n) ? fallback : n
}

function round2(value) {
  return Math.round(value * 100) / 100
}

function emptyMetrics() {
  return {
    adjacentSameCount: 0,
    averagePathTurns: 0,
    averagePathLength: 0,
    availableMoveCount: 0,
    sameLineSolutionPairCount: 0,
    sameLineAvailableMoveCount: 0,
    zeroTurnAvailableMoveCount: 0,
    difficultyScore: 0
  }
}

function createRng(seed) {
  var state = seed >>> 0
  if (state === 0) state = 0x9e3779b9

  return function () {
    state += 0x6D2B79F5
    var t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function mixSeed(seed, salt) {
  var x = (seed >>> 0) ^ Math.imul(salt >>> 0, 0x9e3779b1)
  x ^= x >>> 16
  x = Math.imul(x, 0x85ebca6b)
  x ^= x >>> 13
  x = Math.imul(x, 0xc2b2ae35)
  x ^= x >>> 16
  return x >>> 0
}

function randInt(rng, maxExclusive) {
  return Math.floor(rng() * maxExclusive)
}

function shuffleArray(arr, rng) {
  for (var i = arr.length - 1; i > 0; i--) {
    var j = randInt(rng, i + 1)
    var tmp = arr[i]
    arr[i] = arr[j]
    arr[j] = tmp
  }
  return arr
}

module.exports = {
  generateBoard: generateBoard,
  findConnectionPath: findConnectionPath,
  solveBoard: solveBoard,
  __private__: {
    validateSolution: validateSolution,
    countAdjacentSameCells: countAdjacentSameCells,
    countAvailableMoves: countAvailableMoves,
    calculateMetrics: calculateMetrics
  }
}
