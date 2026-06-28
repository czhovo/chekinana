const { generateBoard } = require('./board-generator')

const ROWS = 12
const COLS = 8
const TILE_TYPES = 14

const HARD_GENERATION_OPTIONS = {
  difficulty: 'hard',
  maxAttempts: 8,
  maxBacktrack: 1600
}

worker.onMessage((message) => {
  if (!message || message.type !== 'generateBoard') return

  try {
    const result = generateBoard({
      rows: ROWS,
      cols: COLS,
      typeCount: TILE_TYPES,
      pairCount: ROWS * COLS / 2,
      difficulty: HARD_GENERATION_OPTIONS.difficulty,
      maxAttempts: HARD_GENERATION_OPTIONS.maxAttempts,
      maxBacktrack: HARD_GENERATION_OPTIONS.maxBacktrack,
      avoidAdjacent: true,
      returnSolution: false,
      randomSeed: Date.now()
    })

    if (!result || !result.ok) {
      worker.postMessage({
        type: 'generatedBoard',
        requestId: message.requestId,
        ok: false,
        errorCode: result && result.errorCode ? result.errorCode : 'GENERATION_FAILED'
      })
      return
    }

    worker.postMessage({
      type: 'generatedBoard',
      requestId: message.requestId,
      ok: true,
      seed: result.seed || 0,
      board: result.board
    })
  } catch (e) {
    worker.postMessage({
      type: 'generatedBoard',
      requestId: message.requestId,
      ok: false,
      errorCode: 'WORKER_ERROR'
    })
  }
})
