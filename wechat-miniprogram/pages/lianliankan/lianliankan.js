const { findConnectionPath } = require('./board-generator')

const { solveBoard } = require('./board-generator')
const PRESET_BOARDS = require('./board-presets')
const lianliankanAssets = require('../../utils/lianliankan-assets')

const ROWS = 12
const COLS = 8
const TOTAL = ROWS * COLS
const TILE_TYPES = 14
const ASSET_MANIFEST_URL = 'https://chekinana.top/assets/lianliankan/v1/manifest.json'
const ASSET_CACHE_KEY = 'lianliankan_asset_cache_v1'
const VICTORY_AUDIO_URL = 'https://chekinana.top/assets/lianliankan/v1/audio/muguang.m4a'
const VICTORY_AUDIO_CACHE_KEY = 'lianliankan_victory_audio_v1'
const VICTORY_AUDIO_DOWNLOAD_ATTEMPTS = 2
const VICTORY_AUDIO_RETRY_DELAY = 1000

const TILE_IMAGE_FILES = [
  '',
  'pattern1r.png',
  'pattern2p.png',
  'pattern3s.png',
  'pattern4g.png',
  'pattern5k.png',
  'pattern6b.png',
  'pattern7w.png',
  'pattern8g.png',
  'pattern9s.png',
  'pattern10p.png',
  'pattern11y.png',
  'pattern12k.png',
  'pattern13r.png',
  'pattern14w.png'
]

const DEFAULT_TILE_IMAGES = Array(TILE_TYPES + 1).fill('')

const COLOR_SUFFIX_CLASS_MAP = {
  y: 'tile-fill-yellow',
  s: 'tile-fill-blue-soft',
  g: 'tile-fill-green',
  p: 'tile-fill-purple',
  w: 'tile-fill-white',
  r: 'tile-fill-red',
  k: 'tile-fill-pink',
  b: 'tile-fill-blue'
}

const TILE_BORDER_CLASS = TILE_IMAGE_FILES.map((file) => {
  if (!file) return ''
  const match = file.match(/([a-zA-Z])(?=\.[a-zA-Z0-9]+$)/)
  if (!match) return ''
  const suffix = match[1].toLowerCase()
  return COLOR_SUFFIX_CLASS_MAP[suffix] || ''
})

function createAssetError(api, url, message) {
  const error = new Error(message || `${api} failed`)
  error.api = api
  error.url = url
  return error
}

function getErrorMessage(err, fallback) {
  return err && err.errMsg ? err.errMsg : err && err.message ? err.message : fallback
}

function downloadFile(url, apiName = 'downloadFile') {
  return new Promise((resolve, reject) => {
    wx.downloadFile({
      url,
      success: (res) => {
        if (res.statusCode >= 200 && res.statusCode < 300 && res.tempFilePath) {
          resolve(res.tempFilePath)
          return
        }
        reject(createAssetError(apiName, url, `status ${res.statusCode || 'unknown'}`))
      },
      fail: (err) => {
        reject(createAssetError(apiName, url, getErrorMessage(err, 'download failed')))
      }
    })
  })
}

function saveFile(tempFilePath, url) {
  return new Promise((resolve, reject) => {
    wx.saveFile({
      tempFilePath,
      success: (res) => {
        if (res.savedFilePath) {
          resolve(res.savedFilePath)
          return
        }
        reject(createAssetError('saveFile', url, 'saveFile returned no path'))
      },
      fail: (err) => {
        reject(createAssetError('saveFile', url, getErrorMessage(err, 'saveFile failed')))
      }
    })
  })
}

function setStorage(key, data) {
  return new Promise((resolve, reject) => {
    wx.setStorage({
      key,
      data,
      success: resolve,
      fail: (err) => {
        reject(new Error(err && err.errMsg ? err.errMsg : 'setStorage failed'))
      }
    })
  })
}

function wait(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}

function canAccessFile(filePath) {
  if (!filePath || typeof wx.getFileSystemManager !== 'function') {
    return Promise.resolve(!!filePath)
  }
  return new Promise((resolve) => {
    wx.getFileSystemManager().access({
      path: filePath,
      success: () => resolve(true),
      fail: () => resolve(false)
    })
  })
}

function formatAssetError(err) {
  const api = err && err.api ? err.api : 'asset'
  const url = err && err.url ? err.url : ASSET_MANIFEST_URL
  const message = err && err.message ? err.message : 'unknown error'
  return `图片资源加载失败：${api} ${url} ${message}。点击重置重试`
}

const BOARD_POOL_KEY = 'hard'
const BOARD_POOL_TARGET_SIZE = 5
const BOARD_POOL_RETRY_DELAY = 1000
const BOARD_POOL_WAIT_DELAY = 200
const BOARD_GENERATOR_WORKER_PATH = 'workers/lianliankan-generator.js'
const boardPools = createInitialBoardPools()
const boardPoolRefillTimers = {}
const boardPoolRefilling = {}
const boardPoolPendingRequests = {}
let boardGeneratorWorker = null
let boardGeneratorWorkerAvailable = false
let boardGeneratorWorkerError = ''
let boardGeneratorRequestId = 0

function createInitialBoardPools() {
  const pools = { [BOARD_POOL_KEY]: [] }
  pools[BOARD_POOL_KEY] = (PRESET_BOARDS.hard || [])
    .filter((entry) => isUsableGeneratedBoard(entry && entry.board))
    .map((entry) => cloneBoardEntry(entry))
  return pools
}

function cloneBoardEntry(entry) {
  return {
    seed: entry.seed || 0,
    board: entry.board.map((row) => row.slice())
  }
}

function isUsableGeneratedBoard(board) {
  if (!Array.isArray(board) || board.length !== ROWS) return false

  const counts = {}
  let filled = 0
  for (let r = 0; r < ROWS; r++) {
    const row = board[r]
    if (!Array.isArray(row) || row.length !== COLS) return false
    for (let c = 0; c < COLS; c++) {
      const tile = row[c]
      if (!Number.isInteger(tile) || tile < 1 || tile > TILE_TYPES) return false
      filled += 1
      counts[tile] = (counts[tile] || 0) + 1
    }
  }

  if (filled !== TOTAL) return false
  return Object.keys(counts).every((key) => counts[key] % 2 === 0)
}

function ensureBoardGeneratorWorker() {
  if (boardGeneratorWorker) return boardGeneratorWorker
  if (typeof wx === 'undefined' || typeof wx.createWorker !== 'function') {
    boardGeneratorWorkerAvailable = false
    boardGeneratorWorkerError = 'wx.createWorker unavailable'
    console.warn('[lianliankan] board generator worker unavailable: wx.createWorker is not a function')
    return null
  }

  try {
    boardGeneratorWorker = wx.createWorker(BOARD_GENERATOR_WORKER_PATH)
    if (!boardGeneratorWorker || typeof boardGeneratorWorker.onMessage !== 'function') {
      boardGeneratorWorker = null
      boardGeneratorWorkerAvailable = false
      boardGeneratorWorkerError = 'invalid worker'
      console.warn('[lianliankan] board generator worker unavailable: invalid worker')
      return null
    }
    boardGeneratorWorkerAvailable = true
    boardGeneratorWorkerError = ''
    console.info('[lianliankan] board generator worker ready')
    boardGeneratorWorker.onMessage((message) => handleBoardGeneratorWorkerMessage(message))
    if (typeof boardGeneratorWorker.onError === 'function') {
      boardGeneratorWorker.onError((error) => {
        boardGeneratorWorkerAvailable = false
        boardGeneratorWorkerError = error && error.message ? error.message : 'worker error'
        console.warn('[lianliankan] board generator worker error', error)
        Object.keys(boardPoolRefilling).forEach((poolKey) => {
          boardPoolRefilling[poolKey] = false
          scheduleBoardPoolRetry(poolKey)
        })
      })
    }
    return boardGeneratorWorker
  } catch (e) {
    boardGeneratorWorker = null
    boardGeneratorWorkerAvailable = false
    boardGeneratorWorkerError = e && e.message ? e.message : 'createWorker failed'
    console.warn('[lianliankan] board generator worker create failed', e)
    return null
  }
}

function handleBoardGeneratorWorkerMessage(message) {
  if (!message || message.type !== 'generatedBoard') return

  const poolKey = boardPoolPendingRequests[message.requestId] || BOARD_POOL_KEY
  delete boardPoolPendingRequests[message.requestId]
  boardPoolRefilling[poolKey] = false

  if (message.ok && isUsableGeneratedBoard(message.board)) {
    const pool = boardPools[poolKey] || []
    boardPools[poolKey] = pool
    if (pool.length < BOARD_POOL_TARGET_SIZE) {
      pool.push({
        seed: message.seed || 0,
        board: message.board
      })
      console.info('[lianliankan] board generated by worker', {
        poolKey,
        poolSize: pool.length,
        seed: message.seed || 0
      })
    }
  } else {
    console.warn('[lianliankan] board generator worker failed', {
      poolKey,
      errorCode: message.errorCode || (message.ok ? 'INVALID_BOARD' : 'UNKNOWN')
    })
  }

  if ((boardPools[poolKey] || []).length < BOARD_POOL_TARGET_SIZE) {
    scheduleBoardPoolRetry(poolKey)
  }
}

function scheduleBoardPoolRetry(poolKey) {
  if (boardPoolRefillTimers[poolKey] || boardPoolRefilling[poolKey]) return
  boardPoolRefillTimers[poolKey] = setTimeout(() => {
    boardPoolRefillTimers[poolKey] = null
    refillBoardPool(poolKey)
  }, BOARD_POOL_RETRY_DELAY)
}

function refillBoardPool(poolKey) {
  const pool = boardPools[poolKey] || []
  boardPools[poolKey] = pool
  if (pool.length >= BOARD_POOL_TARGET_SIZE || boardPoolRefilling[poolKey]) return

  const worker = ensureBoardGeneratorWorker()
  if (!worker) {
    console.warn('[lianliankan] board pool refill skipped: worker unavailable', {
      poolKey,
      error: boardGeneratorWorkerError
    })
    return
  }

  boardPoolRefilling[poolKey] = true
  const requestId = `${poolKey}-${Date.now()}-${boardGeneratorRequestId++}`
  boardPoolPendingRequests[requestId] = poolKey
  try {
    worker.postMessage({ type: 'generateBoard', requestId })
  } catch (e) {
    delete boardPoolPendingRequests[requestId]
    boardPoolRefilling[poolKey] = false
    boardGeneratorWorkerAvailable = false
    boardGeneratorWorkerError = e && e.message ? e.message : 'worker postMessage failed'
    console.warn('[lianliankan] board generator worker postMessage failed', e)
    scheduleBoardPoolRetry(poolKey)
  }
}

function getBoardGeneratorWorkerStatus() {
  return {
    available: boardGeneratorWorkerAvailable,
    error: boardGeneratorWorkerError,
    hasWorker: !!boardGeneratorWorker
  }
}

function takeBoardEntry() {
  const pool = boardPools[BOARD_POOL_KEY] || []
  boardPools[BOARD_POOL_KEY] = pool

  if (pool.length > 0) {
    const index = Math.floor(Math.random() * pool.length)
    const entry = pool.splice(index, 1)[0]
    scheduleBoardPoolRetry(BOARD_POOL_KEY)
    return cloneBoardEntry(entry)
  }

  if (boardPoolRefillTimers[BOARD_POOL_KEY]) {
    clearTimeout(boardPoolRefillTimers[BOARD_POOL_KEY])
    boardPoolRefillTimers[BOARD_POOL_KEY] = null
  }
  refillBoardPool(BOARD_POOL_KEY)
  return null
}

function buildShuffledTileAssets(assetPaths) {
  const tileAssetPaths = assetPaths && assetPaths.length === TILE_TYPES + 1
    ? assetPaths
    : DEFAULT_TILE_IMAGES
  const ids = []
  for (let type = 1; type <= TILE_TYPES; type++) ids.push(type)
  for (let i = ids.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    const tmp = ids[i]
    ids[i] = ids[j]
    ids[j] = tmp
  }

  const tileImages = ['']
  const tileBorderClasses = ['']
  for (let type = 1; type <= TILE_TYPES; type++) {
    const mappedType = ids[type - 1]
    tileImages[type] = tileAssetPaths[mappedType]
    tileBorderClasses[type] = TILE_BORDER_CLASS[mappedType]
  }
  return { tileImages, tileBorderClasses }
}

Page({
  data: {
    rows: ROWS,
    cols: COLS,
    board: [],
    selected: { r: -1, c: -1 },
    status: 'ready',
    statusText: '',
    seconds: 0,
    timer: '0:00',
    pairsLeft: 0,
    lineSegments: [],
    tileImages: DEFAULT_TILE_IMAGES,
    tileBorderClasses: TILE_BORDER_CLASS,
    isAnimating: false,
    isFreshBoard: false,
    isAutoSolving: false,
    isSolvingBoard: false,
    solutionSteps: [],
    audioStatusText: '',
    audioIsPlaying: false,
    audioCurrentTime: 0,
    audioDuration: 0,
    audioProgress: 0,
    audioCurrentLabel: '0:00',
    audioDurationLabel: '0:00'
  },

  timerId: null,
  lineTimerId: null,
  solveTimerId: null,
  boardWaitTimerId: null,
  assetTileImages: null,
  assetLoadPromise: null,
  lastAssetError: null,
  victoryAudioContext: null,
  victoryAudioPlayed: false,
  victoryAudioLocalPath: null,
  victoryAudioDownloadPromise: null,
  victoryAudioDownloadError: null,
  isAudioSeeking: false,
  victoryAudioEnded: false,
  isPageActive: true,

  onLoad() {
    this.loadTileAssetsAndStart()
  },

  onShow() {
    this.isPageActive = true
    if (this.data.status === 'playing') this.startTimer()
    if (this.data.status === 'generating' && !this.boardWaitTimerId) this.tryStartGameFromPool()
    if (typeof wx.hideTabBar === 'function') {
      wx.hideTabBar({ animation: false, fail() {} })
    }
  },

  onHide() {
    this.isPageActive = false
    this.stopTimer()
    this.clearLineTimer()
    this.clearSolveTimer()
    this.clearBoardWaitTimer()
    this.stopVictoryAudio({ destroy: true })
  },

  onUnload() {
    this.isPageActive = false
    this.stopTimer()
    this.clearLineTimer()
    this.clearSolveTimer()
    this.clearBoardWaitTimer()
    this.stopVictoryAudio({ destroy: true })
  },

  loadTileAssetsAndStart(options = {}) {
    this.resetVictoryAudioState()
    this.stopTimer()
    this.clearLineTimer()
    this.clearSolveTimer()
    this.clearBoardWaitTimer()
    if (options.clearCache) this.clearAssetCache()
    this.assetTileImages = null
    this.victoryAudioLocalPath = null
    this.lastAssetError = null
    this.setData({
      board: this.getEmptyBoard(),
      status: 'asset-loading',
      statusText: '正在加载图片资源，请稍等...',
      selected: { r: -1, c: -1 },
      seconds: 0,
      timer: '0:00',
      pairsLeft: 0,
      lineSegments: [],
      tileImages: DEFAULT_TILE_IMAGES,
      isAnimating: false,
      isAutoSolving: false,
      isSolvingBoard: false,
      isFreshBoard: false,
      solutionSteps: []
    })

    const promise = this.ensureTileAssets()
    this.assetLoadPromise = promise
    promise
      .then((tileImages) => {
        if (this.assetLoadPromise !== promise) return
        this.assetTileImages = tileImages
        this.assetLoadPromise = null
        this.startGame()
      })
      .catch((err) => {
        if (this.assetLoadPromise !== promise) return
        console.error('[lianliankan] asset load failed', err)
        this.assetTileImages = null
        this.victoryAudioLocalPath = null
        this.lastAssetError = err
        this.assetLoadPromise = null
        this.setData({
          status: 'asset-error',
          statusText: formatAssetError(err),
          board: this.getEmptyBoard(),
          pairsLeft: 0,
          lineSegments: [],
          isAnimating: false,
          isAutoSolving: false,
          isSolvingBoard: false
        })
      })
  },

  ensureTileAssets() {
    return lianliankanAssets.ensureLianliankanTileAssets()
  },

  async resolveCachedVictoryAudio() {
    const cachedPath = this.victoryAudioLocalPath || wx.getStorageSync(VICTORY_AUDIO_CACHE_KEY)
    if (cachedPath && await canAccessFile(cachedPath)) {
      this.victoryAudioLocalPath = cachedPath
      return cachedPath
    }

    const legacyCache = wx.getStorageSync(ASSET_CACHE_KEY) || {}
    const legacyAudio = legacyCache && legacyCache.audio
    if (legacyAudio && await canAccessFile(legacyAudio)) {
      this.victoryAudioLocalPath = legacyAudio
      await setStorage(VICTORY_AUDIO_CACHE_KEY, legacyAudio)
      return legacyAudio
    }
    return ''
  },

  async downloadVictoryAudioWithRetry() {
    let lastError = null
    for (let attempt = 1; attempt <= VICTORY_AUDIO_DOWNLOAD_ATTEMPTS; attempt++) {
      try {
        const tempFilePath = await downloadFile(VICTORY_AUDIO_URL, 'downloadFile')
        const savedFilePath = await saveFile(tempFilePath, VICTORY_AUDIO_URL)
        if (!await canAccessFile(savedFilePath)) {
          throw createAssetError('saveFile', VICTORY_AUDIO_URL, 'saved file is not accessible')
        }
        return savedFilePath
      } catch (err) {
        lastError = err
        console.warn('[lianliankan] victory audio download failed', {
          attempt,
          maxAttempts: VICTORY_AUDIO_DOWNLOAD_ATTEMPTS,
          error: err
        })
        if (attempt < VICTORY_AUDIO_DOWNLOAD_ATTEMPTS) await wait(VICTORY_AUDIO_RETRY_DELAY)
      }
    }
    throw lastError || createAssetError('downloadFile', VICTORY_AUDIO_URL, 'download failed')
  },

  ensureVictoryAudioDownload() {
    if (this.victoryAudioLocalPath) return Promise.resolve(this.victoryAudioLocalPath)
    if (this.victoryAudioDownloadPromise) return this.victoryAudioDownloadPromise

    const promise = this.resolveCachedVictoryAudio()
      .then((cachedPath) => cachedPath || this.downloadVictoryAudioWithRetry())
      .then((savedFilePath) => {
        this.victoryAudioLocalPath = savedFilePath
        this.victoryAudioDownloadError = null
        return setStorage(VICTORY_AUDIO_CACHE_KEY, savedFilePath)
          .then(() => savedFilePath)
      })
      .catch((err) => {
        this.victoryAudioDownloadError = err
        throw err
      })
      .finally(() => {
        if (this.victoryAudioDownloadPromise === promise) this.victoryAudioDownloadPromise = null
      })

    this.victoryAudioDownloadPromise = promise
    return promise
  },

  startVictoryAudioDownload() {
    this.ensureVictoryAudioDownload().catch((err) => {
      console.warn('[lianliankan] victory audio background download failed', err)
    })
  },

  queueVictoryAudioDownloadAfterRender() {
    if (typeof wx.nextTick === 'function') {
      wx.nextTick(() => this.startVictoryAudioDownload())
      return
    }
    setTimeout(() => this.startVictoryAudioDownload(), 0)
  },

  clearAssetCache() {
    const cached = wx.getStorageSync(ASSET_CACHE_KEY) || {}
    const cachedImages = cached && cached.images ? cached.images : {}
    const cachedAudio = cached && cached.audio
    const cachedVictoryAudio = wx.getStorageSync(VICTORY_AUDIO_CACHE_KEY)
    Object.keys(cachedImages).forEach((key) => {
      const filePath = cachedImages[key]
      if (!filePath) return
      if (typeof wx.removeSavedFile === 'function') {
        wx.removeSavedFile({
          filePath,
          fail() {}
        })
        return
      }
      if (typeof wx.getFileSystemManager === 'function') {
        const fs = wx.getFileSystemManager()
        if (filePath && typeof fs.unlink === 'function') {
          fs.unlink({
            filePath,
            fail() {}
          })
        }
      }
    })
    const cachedAudioPaths = [cachedAudio, cachedVictoryAudio].filter((filePath, index, paths) => {
      return filePath && paths.indexOf(filePath) === index
    })
    cachedAudioPaths.forEach((filePath) => {
      if (typeof wx.removeSavedFile !== 'function') return
      wx.removeSavedFile({
        filePath,
        fail() {}
      })
    })
    if (typeof wx.removeStorageSync === 'function') {
      wx.removeStorageSync(ASSET_CACHE_KEY)
      wx.removeStorageSync(VICTORY_AUDIO_CACHE_KEY)
    }
  },

  startGame() {
    if (!this.assetTileImages) {
      this.loadTileAssetsAndStart({ clearCache: this.data.status === 'asset-error' })
      return
    }
    this.resetVictoryAudioState()
    this.stopTimer()
    this.clearLineTimer()
    this.clearSolveTimer()
    this.clearBoardWaitTimer()
    this.setData({
      board: this.getEmptyBoard(),
      status: 'generating',
      statusText: '正在生成棋盘，请稍等...',
      selected: { r: -1, c: -1 },
      seconds: 0,
      timer: '0:00',
      pairsLeft: 0,
      lineSegments: [],
      isAnimating: false,
      isAutoSolving: false,
      isSolvingBoard: false,
      isFreshBoard: false,
      solutionSteps: []
    })

    if (typeof wx.nextTick === 'function') {
      wx.nextTick(() => this.tryStartGameFromPool())
    } else {
      setTimeout(() => this.tryStartGameFromPool(), 0)
    }
  },

  tryStartGameFromPool() {
    if (this.data.status !== 'generating') return
    this.clearBoardWaitTimer()

    const entry = takeBoardEntry()
    if (!entry) {
      const workerStatus = getBoardGeneratorWorkerStatus()
      this.setData({
        statusText: workerStatus.error ? '棋盘生成器不可用' : '正在准备棋盘，请稍等...'
      })
      this.queueBoardStart(BOARD_POOL_WAIT_DELAY)
      return
    }

    if (!isUsableGeneratedBoard(entry.board)) {
      console.warn('[lianliankan] discarded invalid board entry', {
        seed: entry.seed || 0
      })
      scheduleBoardPoolRetry(BOARD_POOL_KEY)
      this.queueBoardStart(0)
      return
    }

    const tileAssets = buildShuffledTileAssets(this.assetTileImages)
    const board = entry.board
    this.setData({
      board,
      status: 'playing',
      statusText: '',
      selected: { r: -1, c: -1 },
      seconds: 0,
      timer: '0:00',
      tileImages: tileAssets.tileImages,
      tileBorderClasses: tileAssets.tileBorderClasses,
      pairsLeft: this.countPairsLeft(board),
      lineSegments: [],
      isAnimating: false,
      isAutoSolving: false,
      isSolvingBoard: false,
      isFreshBoard: true,
      solutionSteps: []
    }, () => {
      this.startTimer()
      this.queueVictoryAudioDownloadAfterRender()
    })
  },

  queueBoardStart(delay) {
    this.clearBoardWaitTimer()
    this.boardWaitTimerId = setTimeout(() => {
      this.boardWaitTimerId = null
      this.tryStartGameFromPool()
    }, delay)
  },

  getEmptyBoard() {
    return Array.from({ length: ROWS }, () => Array(COLS).fill(0))
  },

  startTimer() {
    this.stopTimer()
    this.timerId = setInterval(() => {
      const next = this.data.seconds + 1
      this.setData({
        seconds: next,
        timer: this.formatTime(next)
      })
    }, 1000)
  },

  stopTimer() {
    if (this.timerId) {
      clearInterval(this.timerId)
      this.timerId = null
    }
  },

  clearLineTimer() {
    if (this.lineTimerId) {
      clearTimeout(this.lineTimerId)
      this.lineTimerId = null
    }
  },

  clearSolveTimer() {
    if (this.solveTimerId) {
      clearTimeout(this.solveTimerId)
      this.solveTimerId = null
    }
  },

  clearBoardWaitTimer() {
    if (this.boardWaitTimerId) {
      clearTimeout(this.boardWaitTimerId)
      this.boardWaitTimerId = null
    }
  },

  getVictoryAudioContext() {
    if (this.victoryAudioContext) return this.victoryAudioContext
    if (typeof wx.createInnerAudioContext !== 'function') {
      console.warn('[lianliankan] victory audio unavailable: wx.createInnerAudioContext is not a function')
      return null
    }

    const audio = wx.createInnerAudioContext()
    audio.src = this.victoryAudioLocalPath || VICTORY_AUDIO_URL
    audio.loop = false
    audio.autoplay = false
    if (typeof audio.onError === 'function') {
      audio.onError((err) => {
        console.warn('[lianliankan] victory audio failed', err)
        this.setData({
          audioIsPlaying: false,
          audioStatusText: '音效播放失败'
        })
      })
    }
    if (typeof audio.onPlay === 'function') {
      audio.onPlay(() => {
        this.victoryAudioEnded = false
        this.setData({
          audioIsPlaying: true,
          audioStatusText: ''
        })
      })
    }
    if (typeof audio.onPause === 'function') {
      audio.onPause(() => {
        this.setData({ audioIsPlaying: false })
      })
    }
    if (typeof audio.onStop === 'function') {
      audio.onStop(() => {
        this.setData({ audioIsPlaying: false })
      })
    }
    if (typeof audio.onEnded === 'function') {
      audio.onEnded(() => {
        const duration = this.normalizeAudioTime(audio.duration || this.data.audioDuration)
        this.victoryAudioEnded = true
        this.setData({
          audioIsPlaying: false,
          audioCurrentTime: duration,
          audioDuration: duration,
          audioProgress: duration > 0 ? 100 : this.data.audioProgress,
          audioCurrentLabel: this.formatAudioTime(duration),
          audioDurationLabel: this.formatAudioTime(duration)
        })
      })
    }
    if (typeof audio.onTimeUpdate === 'function') {
      audio.onTimeUpdate(() => {
        if (this.isAudioSeeking) return
        this.updateAudioProgress(audio.currentTime, audio.duration)
      })
    }
    this.victoryAudioContext = audio
    return audio
  },

  playVictoryAudio() {
    const audio = this.getVictoryAudioContext()
    if (!audio) return

    try {
      audio.src = this.victoryAudioLocalPath || VICTORY_AUDIO_URL
      if (this.victoryAudioEnded && typeof audio.seek === 'function') {
        audio.seek(0)
        this.victoryAudioEnded = false
      }
      audio.play()
      this.setData({
        audioIsPlaying: true,
        audioStatusText: ''
      })
    } catch (e) {
      console.warn('[lianliankan] victory audio play failed', e)
      this.setData({
        audioIsPlaying: false,
        audioStatusText: '音效播放失败'
      })
    }
  },

  playVictoryAudioWhenReady() {
    if (this.victoryAudioPlayed) return

    if (this.victoryAudioLocalPath) {
      this.setData({ audioStatusText: '' })
      this.victoryAudioPlayed = true
      this.playVictoryAudio()
      return
    }

    this.setData({ audioStatusText: '音效下载中...' })
    this.ensureVictoryAudioDownload()
      .then(() => {
        if (!this.isPageActive || this.data.status !== 'won' || this.victoryAudioPlayed) return
        this.setData({ audioStatusText: '' })
        this.victoryAudioPlayed = true
        this.playVictoryAudio()
      })
      .catch((err) => {
        console.warn('[lianliankan] victory audio download unavailable after win', err)
        if (!this.isPageActive || this.data.status !== 'won' || this.victoryAudioPlayed) return
        this.setData({ audioStatusText: '音效下载失败' })
      })
  },

  pauseVictoryAudio() {
    const audio = this.victoryAudioContext
    if (!audio) return
    try {
      if (typeof audio.pause === 'function') audio.pause()
      this.setData({ audioIsPlaying: false })
    } catch (e) {
      console.warn('[lianliankan] victory audio pause failed', e)
    }
  },

  onAudioPlayPauseTap() {
    if (this.data.audioIsPlaying) {
      this.pauseVictoryAudio()
      return
    }

    if (this.victoryAudioLocalPath) {
      this.playVictoryAudio()
      return
    }

    this.setData({ audioStatusText: '音效下载中...' })
    this.ensureVictoryAudioDownload()
      .then(() => {
        if (!this.isPageActive || this.data.status !== 'won') return
        this.setData({ audioStatusText: '' })
        this.playVictoryAudio()
      })
      .catch((err) => {
        console.warn('[lianliankan] victory audio download unavailable from player', err)
        if (!this.isPageActive || this.data.status !== 'won') return
        this.setData({ audioStatusText: '音效下载失败' })
      })
  },

  onAudioSeekChanging(e) {
    this.isAudioSeeking = true
    this.updateAudioProgressFromPercent(e && e.detail ? e.detail.value : 0)
  },

  onAudioSeekChange(e) {
    const percent = this.clampAudioProgress(e && e.detail ? e.detail.value : 0)
    const duration = this.data.audioDuration
    const nextTime = duration > 0 ? duration * percent / 100 : 0
    this.isAudioSeeking = false
    this.updateAudioProgress(nextTime, duration)

    const audio = this.getVictoryAudioContext()
    if (!audio || typeof audio.seek !== 'function' || duration <= 0) return
    try {
      audio.seek(nextTime)
      this.victoryAudioEnded = percent >= 100
    } catch (err) {
      console.warn('[lianliankan] victory audio seek failed', err)
    }
  },

  stopVictoryAudio(options = {}) {
    const audio = this.victoryAudioContext
    if (!audio) return

    try {
      if (typeof audio.stop === 'function') audio.stop()
      this.setData({ audioIsPlaying: false })
    } catch (e) {
      console.warn('[lianliankan] victory audio stop failed', e)
    }

    if (options.destroy && typeof audio.destroy === 'function') {
      try {
        audio.destroy()
      } catch (e) {
        console.warn('[lianliankan] victory audio destroy failed', e)
      }
      this.victoryAudioContext = null
    }
  },

  resetVictoryAudioState() {
    this.victoryAudioPlayed = false
    this.victoryAudioEnded = false
    this.isAudioSeeking = false
    this.stopVictoryAudio()
    this.setData({
      audioStatusText: '',
      audioIsPlaying: false,
      audioCurrentTime: 0,
      audioDuration: 0,
      audioProgress: 0,
      audioCurrentLabel: '0:00',
      audioDurationLabel: '0:00'
    })
  },

  formatTime(seconds) {
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    return `${m}:${s.toString().padStart(2, '0')}`
  },

  normalizeAudioTime(value) {
    const next = Number(value)
    if (!Number.isFinite(next) || next < 0) return 0
    return next
  },

  clampAudioProgress(value) {
    const next = Number(value)
    if (!Number.isFinite(next)) return 0
    return Math.max(0, Math.min(100, next))
  },

  formatAudioTime(seconds) {
    const safeSeconds = Math.floor(this.normalizeAudioTime(seconds))
    const m = Math.floor(safeSeconds / 60)
    const s = safeSeconds % 60
    return `${m}:${s.toString().padStart(2, '0')}`
  },

  updateAudioProgress(currentTime, duration) {
    const safeCurrent = this.normalizeAudioTime(currentTime)
    const safeDuration = this.normalizeAudioTime(duration || this.data.audioDuration)
    const progress = safeDuration > 0 ? this.clampAudioProgress(safeCurrent / safeDuration * 100) : 0
    this.setData({
      audioCurrentTime: safeCurrent,
      audioDuration: safeDuration,
      audioProgress: progress,
      audioCurrentLabel: this.formatAudioTime(safeCurrent),
      audioDurationLabel: this.formatAudioTime(safeDuration)
    })
  },

  updateAudioProgressFromPercent(percent) {
    const safePercent = this.clampAudioProgress(percent)
    const duration = this.data.audioDuration
    const current = duration > 0 ? duration * safePercent / 100 : 0
    this.setData({
      audioCurrentTime: current,
      audioProgress: safePercent,
      audioCurrentLabel: this.formatAudioTime(current)
    })
  },

  cloneBoard(board) {
    return board.map((row) => row.slice())
  },

  countPairsLeft(board) {
    let filled = 0
    for (let r = 0; r < ROWS; r++) {
      for (let c = 0; c < COLS; c++) {
        if (board[r][c] > 0) filled += 1
      }
    }
    return Math.floor(filled / 2)
  },

  onCellTap(e) {
    if (this.data.status !== 'playing' || this.data.isAnimating || this.data.isAutoSolving || this.data.isSolvingBoard) return

    const idx = Number(e.currentTarget.dataset.index)
    const r = Math.floor(idx / this.data.cols)
    const c = idx % this.data.cols
    const board = this.cloneBoard(this.data.board)

    if (board[r][c] === 0) return

    const sel = this.data.selected
    if (sel.r === -1 && sel.c === -1) {
      this.setData({
        selected: { r, c },
        statusText: ''
      })
      return
    }

    if (sel.r === r && sel.c === c) {
      this.setData({
        selected: { r: -1, c: -1 },
        statusText: ''
      })
      return
    }

    const curTile = board[r][c]
    const prevTile = board[sel.r][sel.c]
    const path = this.findConnectionPath(board, sel.r, sel.c, r, c)

    if (prevTile === curTile && path) {
      this.setData({
        isAnimating: true,
        statusText: '',
        selected: { r: -1, c: -1 },
        isFreshBoard: false
      })

      this.showConnectionLine(path)
      this.lineTimerId = setTimeout(() => {
        board[sel.r][sel.c] = 0
        board[r][c] = 0

        const pairsLeft = this.countPairsLeft(board)
        const won = pairsLeft === 0
        this.setData({
          board,
          lineSegments: [],
          selected: { r: -1, c: -1 },
          pairsLeft,
          isAnimating: false,
          status: won ? 'won' : 'playing',
          statusText: ''
        })
        if (won) {
          this.stopTimer()
          this.playVictoryAudioWhenReady()
        }
      }, 500)
      return
    }

    if (prevTile !== curTile) {
      this.setData({
        selected: { r: -1, c: -1 },
        statusText: '图片不同'
      })
      return
    }

    this.setData({
      selected: { r: -1, c: -1 },
      statusText: '路径不合法'
    })
  },

  showConnectionLine(path) {
    if (!path || path.length < 2) return
    const query = wx.createSelectorQuery().in(this)
    query.select('.board-wrap').boundingClientRect()
    query.selectAll('.cell').boundingClientRect()
    query.exec((res) => {
      const wrapRect = res[0] || {}
      const cells = res[1] || []
      if (cells.length < TOTAL) return

      const boardLeft = wrapRect.left || 0
      const boardTop = wrapRect.top || 0
      const first = cells[0]
      const secondCol = cells[1]
      const secondRow = cells[COLS]

      const stepX = secondCol.left - first.left
      const stepY = secondRow.top - first.top
      const toPixel = (point) => ({
        x: first.left + first.width / 2 + point.c * stepX - boardLeft,
        y: first.top + first.height / 2 + point.r * stepY - boardTop
      })

      const points = path.map((point) => toPixel(point))
      const segments = []
      const half = 2

      for (let i = 0; i < points.length - 1; i++) {
        const a = points[i]
        const b = points[i + 1]
        if (a.x === b.x) {
          const top = Math.min(a.y, b.y)
          const height = Math.abs(a.y - b.y)
          if (height <= 0) continue
          segments.push({
            style: `left:${a.x - half}px; top:${top}px; width:${half * 2}px; height:${height}px;`
          })
        } else if (a.y === b.y) {
          const left = Math.min(a.x, b.x)
          const width = Math.abs(a.x - b.x)
          if (width <= 0) continue
          segments.push({
            style: `left:${left}px; top:${a.y - half}px; width:${width}px; height:${half * 2}px;`
          })
        }
      }

      this.setData({ lineSegments: segments })
    })
  },

  onAnswerTap() {
    if (this.data.isAutoSolving) {
      this.pauseAutoSolve()
      return
    }

    if (this.data.status !== 'playing' || this.data.isSolvingBoard || this.data.pairsLeft <= 0) return

    this.clearSolveTimer()
    this.clearLineTimer()
    this.setData({
      isSolvingBoard: true,
      lineSegments: [],
      selected: { r: -1, c: -1 },
      statusText: '正在求解...'
    }, () => {
      setTimeout(() => this.solveAndPlayCurrentBoard(), 0)
    })
  },

  pauseAutoSolve() {
    this.clearSolveTimer()
    this.clearLineTimer()
    this.setData({
      isAutoSolving: false,
      isAnimating: false,
      lineSegments: [],
      statusText: '已暂停'
    })
  },

  solveAndPlayCurrentBoard() {
    if (!this.data.isSolvingBoard || this.data.status !== 'playing') return

    const board = this.cloneBoard(this.data.board)
    const result = solveBoard(board, { maxMs: 10000, sliceMs: 1000 })

    if (!result.ok) {
      this.setData({
        isSolvingBoard: false,
        isAutoSolving: false,
        solutionSteps: [],
        statusText: result.errorCode === 'SEARCH_LIMIT' ? '求解超时' : '当前棋盘无解'
      })
      return
    }

    if (!result.solutionSteps || result.solutionSteps.length === 0) {
      this.setData({
        isSolvingBoard: false,
        isAutoSolving: false,
        status: 'won',
        statusText: ''
      })
      this.stopTimer()
      this.playVictoryAudioWhenReady()
      return
    }

    this.setData({
      isSolvingBoard: false,
      isAutoSolving: true,
      isFreshBoard: false,
      solutionSteps: result.solutionSteps,
      statusText: ''
    })
    this.playAnswerStep(board, 0)
  },

  playAnswerStep(board, stepIndex) {
    if (!this.data.isAutoSolving) return

    const steps = this.data.solutionSteps || []
    if (stepIndex >= steps.length) {
      const won = this.countPairsLeft(board) === 0
      this.setData({
        isAutoSolving: false,
        status: won ? 'won' : 'playing',
        statusText: ''
      })
      if (won) {
        this.stopTimer()
        this.playVictoryAudioWhenReady()
      }
      return
    }

    const step = steps[stepIndex]
    if (!step || !step.a || !step.b) {
      this.clearSolveTimer()
      this.solveTimerId = setTimeout(() => this.playAnswerStep(board, stepIndex + 1), 0)
      return
    }

    const a = step.a
    const b = step.b
    const aType = board[a.r] && board[a.r][a.c]
    const bType = board[b.r] && board[b.r][b.c]
    if (!aType || !bType || aType !== bType) {
      this.clearSolveTimer()
      this.solveTimerId = setTimeout(() => this.playAnswerStep(board, stepIndex + 1), 0)
      return
    }

    const path = Array.isArray(step.path) ? step.path : this.findConnectionPath(board, a.r, a.c, b.r, b.c)
    if (!path) {
      this.clearSolveTimer()
      this.solveTimerId = setTimeout(() => this.playAnswerStep(board, stepIndex + 1), 0)
      return
    }

    this.showConnectionLine(path)
    this.setData({ isAnimating: true })
    this.lineTimerId = setTimeout(() => {
      const nextBoard = this.cloneBoard(board)
      nextBoard[a.r][a.c] = 0
      nextBoard[b.r][b.c] = 0
      const pairsLeft = this.countPairsLeft(nextBoard)
      const won = pairsLeft === 0
      this.setData({
        board: nextBoard,
        lineSegments: [],
        selected: { r: -1, c: -1 },
        pairsLeft,
        isAnimating: false,
        status: won ? 'won' : 'playing'
      })

      if (won) {
        this.stopTimer()
        this.setData({ isAutoSolving: false, statusText: '' })
        this.playVictoryAudioWhenReady()
        return
      }

      this.clearSolveTimer()
      this.solveTimerId = setTimeout(() => this.playAnswerStep(nextBoard, stepIndex + 1), 0)
    }, 500)
  },

  findConnectionPath(board, r1, c1, r2, c2) {
    return findConnectionPath(board, r1, c1, r2, c2, { rawPath: true })
  }
})
