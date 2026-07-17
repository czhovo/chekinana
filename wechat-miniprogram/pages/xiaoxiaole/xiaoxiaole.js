const ROWS = 8
const COLS = 8
const BOARD_SIZE = ROWS * COLS
const BASE_EFFECT = 100
const SPECIAL_DAMAGE = 300
const MAX_CASCADES = 30
const TILE_IMAGES = {
  physical: './images/physical.png',
  magic: './images/magic.png',
  heal: './images/heal.png',
  spirit: './images/spirit.png',
  special: './images/special.png'
}
const ANIMATION_DELAY = {
  swap: 180,
  match: 240,
  remove: 210,
  fall: 280,
  detonate: 220
}

const PIECES = [
  { type: 'physical', label: '物', name: '物理', effect: 'physical' },
  { type: 'magic', label: '法', name: '魔法', effect: 'magic' },
  { type: 'heal', label: '愈', name: '回血', effect: 'heal' },
  { type: 'spirit', label: '灵', name: '精神', effect: 'spirit' }
]

const PIECE_BY_TYPE = PIECES.reduce((map, piece) => {
  map[piece.type] = piece
  return map
}, {})

const PLAYER_MAX_HP = 1000
const PLAYER_MAX_SPIRIT = 1000
const NPC_MAX_HP = 20000
const NPC_SKILL_INTERVAL = 3
const NPC_SKILLS = [
  { name: '暗刃', effect: '对玩家造成300点伤害' },
  { name: '汲取', effect: '回复NPC 450点生命' },
  { name: '障壁', effect: '在棋盘上制造4个障碍' }
]

const PLAYER_SKILLS = [
  {
    id: 'power-strike',
    name: '破甲击',
    desc: '300物伤',
    cost: 200,
    cooldown: 3,
    action: 'physicalDamage',
    value: 300
  },
  {
    id: 'arcane-bolt',
    name: '星火术',
    desc: '450魔伤',
    cost: 260,
    cooldown: 3,
    action: 'magicDamage',
    value: 450
  },
  {
    id: 'renew',
    name: '复苏',
    desc: '回复350',
    cost: 180,
    cooldown: 3,
    action: 'heal',
    value: 350
  },
  {
    id: 'forge',
    name: '炼成',
    desc: '造2枚升级',
    cost: 220,
    cooldown: 4,
    action: 'upgradeTiles',
    value: 2
  },
  {
    id: 'starfall',
    name: '星核',
    desc: '造特殊棋',
    cost: 300,
    cooldown: 5,
    action: 'specialTile',
    value: 1
  }
]

let nextTileId = 1

function randomPieceType() {
  return PIECES[Math.floor(Math.random() * PIECES.length)].type
}

function makeTile(type, level) {
  const piece = PIECE_BY_TYPE[type]
  return {
    id: nextTileId++,
    type,
    level: level || 1,
    label: piece.label,
    name: piece.name,
    imageSrc: TILE_IMAGES[type],
    special: false,
    obstacle: false
  }
}

function makeSpecialTile() {
  return {
    id: nextTileId++,
    type: 'special',
    level: 1,
    label: '爆',
    name: '特殊',
    imageSrc: TILE_IMAGES.special,
    special: true,
    obstacle: false
  }
}

function makeObstacleTile() {
  return {
    id: nextTileId++,
    type: 'obstacle',
    level: 1,
    label: '障',
    name: '障碍',
    imageSrc: '',
    special: false,
    obstacle: true
  }
}

function posToIndex(row, col) {
  return row * COLS + col
}

function indexToPos(index) {
  return {
    row: Math.floor(index / COLS),
    col: index % COLS
  }
}

function cloneBoard(board) {
  return board.map((tile) => {
    if (!tile || tile.empty || tile.type === 'empty') return null
    return Object.assign({}, tile)
  })
}

function isMatchable(tile) {
  return tile && PIECE_BY_TYPE[tile.type] && !tile.special && !tile.obstacle
}

function tileClass(tile, selected, animationClass) {
  if (!tile) return 'empty'
  const classes = [selected ? 'selected' : '', animationClass || '']
  if (tile.obstacle) {
    classes.push('obstacle')
  } else if (tile.special) {
    classes.push('special')
  } else {
    classes.push('type-' + tile.type)
    if (tile.level > 1) classes.push('level-two')
  }
  return classes.join(' ')
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}

function makeFlagMap(indexes, className) {
  const flags = {}
  indexes.forEach((index) => {
    flags[index] = className
  })
  return flags
}

function decorateBoard(board, selectedIndex, animationFlags) {
  const flags = animationFlags || {}
  return board.map((tile, index) => {
    if (!tile) {
      return {
        id: 'empty-' + index,
        label: '',
        type: 'empty',
        className: tileClass(null, selectedIndex === index, flags[index]),
        levelText: '',
        specialText: '',
        imageSrc: '',
        empty: true
      }
    }
    return Object.assign({}, tile, {
      className: tileClass(tile, selectedIndex === index, flags[index]),
      levelText: tile.level > 1 ? 'x2' : '',
      specialText: tile.special ? 'SP' : '',
      empty: false
    })
  })
}

function percent(value, max) {
  return Math.max(0, Math.min(100, Math.round((value / max) * 100)))
}

function buildSkillsView(skills, spirit, gameOver) {
  return skills.map((skill) => Object.assign({}, skill, {
    disabled: gameOver || spirit < skill.cost || skill.remainingCooldown > 0,
    cooldownText: skill.remainingCooldown > 0 ? skill.remainingCooldown + 'T' : ''
  }))
}

function buildNpcSkillsView(nextIndex) {
  return NPC_SKILLS.map((skill, index) => Object.assign({}, skill, {
    active: index === nextIndex % NPC_SKILLS.length
  }))
}

function makeInitialSkills() {
  return PLAYER_SKILLS.map((skill) => Object.assign({}, skill, {
    remainingCooldown: 0
  }))
}

function areAdjacent(first, second) {
  const a = indexToPos(first)
  const b = indexToPos(second)
  return Math.abs(a.row - b.row) + Math.abs(a.col - b.col) === 1
}

function collectRuns(board) {
  const runs = []

  for (let row = 0; row < ROWS; row += 1) {
    let col = 0
    while (col < COLS) {
      const start = col
      const tile = board[posToIndex(row, col)]
      if (!isMatchable(tile)) {
        col += 1
        continue
      }
      col += 1
      while (col < COLS) {
        const next = board[posToIndex(row, col)]
        if (!isMatchable(next) || next.type !== tile.type) break
        col += 1
      }
      if (col - start >= 3) {
        const cells = []
        for (let c = start; c < col; c += 1) cells.push(posToIndex(row, c))
        runs.push({ cells, type: tile.type, orientation: 'h', length: cells.length })
      }
    }
  }

  for (let col = 0; col < COLS; col += 1) {
    let row = 0
    while (row < ROWS) {
      const start = row
      const tile = board[posToIndex(row, col)]
      if (!isMatchable(tile)) {
        row += 1
        continue
      }
      row += 1
      while (row < ROWS) {
        const next = board[posToIndex(row, col)]
        if (!isMatchable(next) || next.type !== tile.type) break
        row += 1
      }
      if (row - start >= 3) {
        const cells = []
        for (let r = start; r < row; r += 1) cells.push(posToIndex(r, col))
        runs.push({ cells, type: tile.type, orientation: 'v', length: cells.length })
      }
    }
  }

  return runs
}

function findMatches(board) {
  const runs = collectRuns(board)
  if (!runs.length) return []

  const parents = runs.map((_, index) => index)
  const find = (index) => {
    while (parents[index] !== index) {
      parents[index] = parents[parents[index]]
      index = parents[index]
    }
    return index
  }
  const union = (a, b) => {
    const rootA = find(a)
    const rootB = find(b)
    if (rootA !== rootB) parents[rootB] = rootA
  }

  for (let i = 0; i < runs.length; i += 1) {
    const set = new Set(runs[i].cells)
    for (let j = i + 1; j < runs.length; j += 1) {
      if (runs[i].type !== runs[j].type) continue
      if (runs[j].cells.some((cell) => set.has(cell))) {
        union(i, j)
      }
    }
  }

  const groups = {}
  runs.forEach((run, index) => {
    const root = find(index)
    if (!groups[root]) {
      groups[root] = {
        type: run.type,
        cells: new Set(),
        runs: [],
        hasHorizontal: false,
        hasVertical: false,
        maxRun: 0
      }
    }
    run.cells.forEach((cell) => groups[root].cells.add(cell))
    groups[root].runs.push(run)
    groups[root].hasHorizontal = groups[root].hasHorizontal || run.orientation === 'h'
    groups[root].hasVertical = groups[root].hasVertical || run.orientation === 'v'
    groups[root].maxRun = Math.max(groups[root].maxRun, run.length)
  })

  return Object.keys(groups).map((key) => {
    const group = groups[key]
    const cells = Array.from(group.cells)
    const isBentFive = group.hasHorizontal && group.hasVertical && cells.length >= 5
    const isStraightFive = !isBentFive && group.maxRun >= 5
    const isFour = !isStraightFive && group.maxRun === 4
    return Object.assign({}, group, {
      cells,
      isBentFive,
      isStraightFive,
      isFour,
      multiplier: isFour || isBentFive ? 2 : 1
    })
  })
}

function hasMatches(board) {
  return findMatches(board).length > 0
}

function applyGravityAndFill(board) {
  const createdIndexes = []
  const movedIndexes = []
  for (let col = 0; col < COLS; col += 1) {
    let row = ROWS - 1
    while (row >= 0) {
      if (board[posToIndex(row, col)] && board[posToIndex(row, col)].obstacle) {
        row -= 1
        continue
      }

      const bottom = row
      while (row >= 0 && !(board[posToIndex(row, col)] && board[posToIndex(row, col)].obstacle)) {
        row -= 1
      }
      const top = row + 1
      const tiles = []
      for (let r = top; r <= bottom; r += 1) {
        const tile = board[posToIndex(r, col)]
        if (tile) {
          tiles.push({
            tile,
            from: posToIndex(r, col)
          })
        }
      }
      for (let r = bottom; r >= top; r -= 1) {
        const index = posToIndex(r, col)
        if (tiles.length) {
          const moved = tiles.pop()
          board[index] = moved.tile
          if (moved.from !== index) movedIndexes.push(index)
        } else {
          board[index] = makeTile(randomPieceType(), 1)
          createdIndexes.push(index)
        }
      }
    }
  }
  return {
    createdIndexes,
    movedIndexes
  }
}

function safeRandomTile(board, index) {
  const pos = indexToPos(index)
  const candidates = PIECES.map((piece) => piece.type).filter((type) => {
    const leftOne = pos.col >= 1 ? board[posToIndex(pos.row, pos.col - 1)] : null
    const leftTwo = pos.col >= 2 ? board[posToIndex(pos.row, pos.col - 2)] : null
    const upOne = pos.row >= 1 ? board[posToIndex(pos.row - 1, pos.col)] : null
    const upTwo = pos.row >= 2 ? board[posToIndex(pos.row - 2, pos.col)] : null
    if (leftOne && leftTwo && leftOne.type === type && leftTwo.type === type) return false
    if (upOne && upTwo && upOne.type === type && upTwo.type === type) return false
    return true
  })
  const type = candidates[Math.floor(Math.random() * candidates.length)]
  return makeTile(type, 1)
}

function createFreshBoard() {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    const board = []
    for (let index = 0; index < BOARD_SIZE; index += 1) {
      board.push(safeRandomTile(board, index))
    }
    if (!hasMatches(board) && hasAvailableMove(board)) return board
  }

  const fallback = []
  for (let index = 0; index < BOARD_SIZE; index += 1) {
    const pos = indexToPos(index)
    fallback.push(makeTile(PIECES[(pos.row * 2 + pos.col) % PIECES.length].type, 1))
  }
  fallback[posToIndex(0, 0)] = makeTile('physical', 1)
  fallback[posToIndex(0, 1)] = makeTile('physical', 1)
  fallback[posToIndex(0, 2)] = makeTile('magic', 1)
  fallback[posToIndex(1, 2)] = makeTile('physical', 1)
  return fallback
}

function hasAvailableMove(board) {
  for (let index = 0; index < BOARD_SIZE; index += 1) {
    const tile = board[index]
    if (!isMatchable(tile)) continue
    const pos = indexToPos(index)
    const candidates = []
    if (pos.col + 1 < COLS) candidates.push(posToIndex(pos.row, pos.col + 1))
    if (pos.row + 1 < ROWS) candidates.push(posToIndex(pos.row + 1, pos.col))
    for (let i = 0; i < candidates.length; i += 1) {
      const nextIndex = candidates[i]
      if (!isMatchable(board[nextIndex])) continue
      const copy = cloneBoard(board)
      const temp = copy[index]
      copy[index] = copy[nextIndex]
      copy[nextIndex] = temp
      if (hasMatches(copy)) return true
    }
  }
  return false
}

function chooseAnchor(group, preferredIndex) {
  if (preferredIndex !== undefined && group.cells.indexOf(preferredIndex) !== -1) {
    return preferredIndex
  }
  return group.cells.slice().sort((a, b) => a - b)[Math.floor(group.cells.length / 2)]
}

function getMutableIndexes(board) {
  const indexes = []
  board.forEach((tile, index) => {
    if (isMatchable(tile)) indexes.push(index)
  })
  return indexes
}

function pickRandomIndexes(source, count) {
  const pool = source.slice()
  const picked = []
  while (pool.length && picked.length < count) {
    const index = Math.floor(Math.random() * pool.length)
    picked.push(pool.splice(index, 1)[0])
  }
  return picked
}

function ensureAvailableMove(board) {
  if (hasAvailableMove(board)) return false
  for (let row = 0; row < ROWS - 1; row += 1) {
    for (let col = 0; col < COLS - 2; col += 1) {
      const indexes = [
        posToIndex(row, col),
        posToIndex(row, col + 1),
        posToIndex(row, col + 2),
        posToIndex(row + 1, col + 2)
      ]
      if (indexes.every((index) => board[index] && !board[index].obstacle)) {
        board[indexes[0]] = makeTile('physical', 1)
        board[indexes[1]] = makeTile('physical', 1)
        board[indexes[2]] = makeTile('magic', 1)
        board[indexes[3]] = makeTile('physical', 1)
        return true
      }
    }
  }
  return false
}

Page({
  data: {
    board: [],
    selectedIndex: null,
    playerHp: PLAYER_MAX_HP,
    playerSpirit: PLAYER_MAX_SPIRIT,
    npcHp: NPC_MAX_HP,
    playerHpPercent: 100,
    playerSpiritPercent: 100,
    npcHpPercent: 100,
    turn: 1,
    npcCountdown: NPC_SKILL_INTERVAL,
    score: 0,
    comboText: '0',
    skills: [],
    npcSkills: [],
    settlementText: '等待消除',
    gameOver: false,
    isAnimating: false,
    resultTitle: '',
    resultGrade: '',
    npcSkillIndex: 0
  },

  onLoad() {
    if (typeof wx.hideTabBar === 'function') {
      wx.hideTabBar({ animation: false, fail() {} })
    }
    this.startGame()
  },

  startGame() {
    const board = createFreshBoard()
    this.setData({
      board: decorateBoard(board, null),
      selectedIndex: null,
      playerHp: PLAYER_MAX_HP,
      playerSpirit: PLAYER_MAX_SPIRIT,
      npcHp: NPC_MAX_HP,
      playerHpPercent: 100,
      playerSpiritPercent: 100,
      npcHpPercent: 100,
      turn: 1,
      npcCountdown: NPC_SKILL_INTERVAL,
      score: 0,
      comboText: '0',
      skills: buildSkillsView(makeInitialSkills(), PLAYER_MAX_SPIRIT, false),
      npcSkills: buildNpcSkillsView(0),
      settlementText: '等待消除',
      gameOver: false,
      isAnimating: false,
      resultTitle: '',
      resultGrade: '',
      npcSkillIndex: 0
    })
  },

  handleRestart() {
    this.dragStart = null
    this.dragCurrent = null
    this.startGame()
  },

  handleTileTouchStart(event) {
    if (this.data.gameOver || this.data.isAnimating) return
    const touch = event.touches && event.touches[0]
    if (!touch) return
    this.dragStart = {
      index: Number(event.currentTarget.dataset.index),
      x: touch.clientX,
      y: touch.clientY
    }
  },

  handleTileTouchMove(event) {
    if (!this.dragStart || this.data.gameOver || this.data.isAnimating) return
    const touch = event.touches && event.touches[0]
    if (!touch) return
    this.dragCurrent = {
      x: touch.clientX,
      y: touch.clientY
    }
  },

  handleTileTouchEnd(event) {
    if (!this.dragStart || this.data.gameOver || this.data.isAnimating) return
    const touch = event.changedTouches && event.changedTouches[0]
    const end = touch || this.dragCurrent
    const start = this.dragStart
    this.dragStart = null
    this.dragCurrent = null
    if (!end) return

    const dx = end.clientX - start.x
    const dy = end.clientY - start.y
    const distance = Math.max(Math.abs(dx), Math.abs(dy))
    if (distance < 18) return

    const pos = indexToPos(start.index)
    let targetRow = pos.row
    let targetCol = pos.col
    if (Math.abs(dx) > Math.abs(dy)) {
      targetCol += dx > 0 ? 1 : -1
    } else {
      targetRow += dy > 0 ? 1 : -1
    }
    if (targetRow < 0 || targetRow >= ROWS || targetCol < 0 || targetCol >= COLS) return
    return this.performDragSwap(start.index, posToIndex(targetRow, targetCol))
  },

  async performDragSwap(firstIndex, secondIndex) {
    if (this.data.gameOver || this.data.isAnimating) return
    const board = cloneBoard(this.data.board)
    const first = board[firstIndex]
    const second = board[secondIndex]
    if (!first || !second || first.obstacle || second.obstacle) return
    if (!areAdjacent(firstIndex, secondIndex)) return

    if (first.special || second.special) {
      this.settleText('特殊棋需长按引爆，障碍不可移动')
      return
    }

    const temp = board[firstIndex]
    board[firstIndex] = board[secondIndex]
    board[secondIndex] = temp
    this.setData({
      board: decorateBoard(board, null, makeFlagMap([firstIndex, secondIndex], 'swapping')),
      selectedIndex: null,
      isAnimating: true
    })
    await sleep(ANIMATION_DELAY.swap)

    if (!hasMatches(board)) {
      const reverted = cloneBoard(board)
      const back = reverted[firstIndex]
      reverted[firstIndex] = reverted[secondIndex]
      reverted[secondIndex] = back
      this.setData({
        board: decorateBoard(reverted, null, makeFlagMap([firstIndex, secondIndex], 'invalid-swap')),
        isAnimating: true
      })
      await sleep(ANIMATION_DELAY.swap)
      this.setData({
        board: decorateBoard(reverted, null),
        isAnimating: false
      })
      this.settleText('未形成三消')
      return
    }

    const result = await this.resolveBoardAnimated(board, secondIndex)
    this.finishPlayerAction(result.board, result.comboCount)
  },

  async handleTileLongPress(event) {
    if (this.data.gameOver || this.data.isAnimating) return
    const index = Number(event.currentTarget.dataset.index)
    const board = cloneBoard(this.data.board)
    const tile = board[index]
    if (!tile || !tile.special) return

    this.setData({ isAnimating: true })
    const result = await this.detonateSpecialsAnimated(board, index)
    const cascade = await this.resolveBoardAnimated(result.board, undefined)
    this.finishPlayerAction(cascade.board, Math.max(result.chain, cascade.comboCount))
  },

  handleSkillTap(event) {
    if (this.data.gameOver || this.data.isAnimating) return
    const index = event.currentTarget.dataset.index
    const skills = this.data.skills.map((skill) => Object.assign({}, skill))
    const skill = skills[index]
    if (!skill || skill.disabled) return

    let playerSpirit = this.data.playerSpirit - skill.cost
    let playerHp = this.data.playerHp
    let npcHp = this.data.npcHp
    let score = this.data.score + 80
    const board = cloneBoard(this.data.board)
    let settlementText = ''

    if (skill.action === 'physicalDamage') {
      npcHp -= skill.value
      settlementText = skill.name + '：物理伤害' + skill.value
    } else if (skill.action === 'magicDamage') {
      npcHp -= skill.value
      settlementText = skill.name + '：魔法伤害' + skill.value
    } else if (skill.action === 'heal') {
      playerHp = Math.min(PLAYER_MAX_HP, playerHp + skill.value)
      settlementText = skill.name + '：回复生命' + skill.value
    } else if (skill.action === 'upgradeTiles') {
      const indexes = pickRandomIndexes(getMutableIndexes(board), skill.value)
      indexes.forEach((tileIndex) => {
        board[tileIndex] = makeTile(board[tileIndex].type, 2)
      })
      score += indexes.length * 220
      settlementText = skill.name + '：制造' + indexes.length + '枚升级棋子'
    } else if (skill.action === 'specialTile') {
      const indexes = pickRandomIndexes(getMutableIndexes(board), skill.value)
      indexes.forEach((tileIndex) => {
        board[tileIndex] = makeSpecialTile()
      })
      score += indexes.length * 500
      settlementText = skill.name + '：制造特殊棋子'
    }

    skill.remainingCooldown = skill.cooldown

    let gameOverState = this.evaluateGameOver(playerHp, npcHp, score)
    if (gameOverState.gameOver && gameOverState.resultTitle === '胜利') {
      score += 2000
      gameOverState = this.evaluateGameOver(playerHp, npcHp, score)
    }
    this.setData({
      board: decorateBoard(board, this.data.selectedIndex),
      playerHp,
      playerSpirit,
      npcHp,
      score,
      playerHpPercent: percent(playerHp, PLAYER_MAX_HP),
      playerSpiritPercent: percent(playerSpirit, PLAYER_MAX_SPIRIT),
      npcHpPercent: percent(npcHp, NPC_MAX_HP),
      skills: buildSkillsView(skills, playerSpirit, gameOverState.gameOver),
      settlementText,
      gameOver: gameOverState.gameOver,
      resultTitle: gameOverState.resultTitle,
      resultGrade: gameOverState.resultGrade
    })
  },

  updateBoard(board, selectedIndex) {
    this.setData({
      board: decorateBoard(board, selectedIndex),
      selectedIndex
    })
  },

  settleText(message) {
    this.setData({
      settlementText: message
    })
  },

  async resolveBoardAnimated(startBoard, preferredIndex) {
    const board = cloneBoard(startBoard)
    let comboCount = 0

    while (comboCount < MAX_CASCADES) {
      let groups = findMatches(board)
      if (!groups.length) break

      comboCount += 1
      const removals = new Set()
      const creations = {}
      const matchedCells = new Set()
      const waveEffects = { physical: 0, magic: 0, heal: 0, spirit: 0 }
      let waveScore = 0
      const waveNotes = []

      groups.forEach((group) => {
        const anchor = group.isStraightFive || group.isFour || group.isBentFive
          ? chooseAnchor(group, preferredIndex)
          : null
        const creationType = group.type

        group.cells.forEach((cell) => {
          const tile = board[cell]
          if (!tile) return
          const value = BASE_EFFECT * (tile.level || 1) * group.multiplier
          waveEffects[PIECE_BY_TYPE[tile.type].effect] += value
          matchedCells.add(cell)
        })

        if (anchor !== null) {
          if (group.isStraightFive) {
            creations[anchor] = makeSpecialTile()
            waveScore += 900
            waveNotes.push('直线五消生成特殊棋')
          } else {
            creations[anchor] = makeTile(creationType, 2)
            waveScore += 450
            waveNotes.push((group.isBentFive ? 'L形五消' : '四消') + '生成升级棋')
          }
        }

        group.cells.forEach((cell) => {
          if (String(cell) !== String(anchor)) removals.add(cell)
        })
        waveScore += group.cells.length * 40 * comboCount
      })

      this.setData({
        board: decorateBoard(board, null, makeFlagMap(Array.from(matchedCells), 'matching'))
      })
      await sleep(ANIMATION_DELAY.match)
      this.applyImmediateSettlement(waveEffects, waveScore, comboCount, waveNotes)
      this.setData({
        board: decorateBoard(board, null, makeFlagMap(Array.from(removals), 'removing'))
      })
      await sleep(ANIMATION_DELAY.remove)

      removals.forEach((cell) => {
        board[cell] = null
      })
      Object.keys(creations).forEach((cell) => {
        board[cell] = creations[cell]
      })
      this.setData({
        board: decorateBoard(board, null, makeFlagMap(Object.keys(creations).map(Number), 'created'))
      })
      await sleep(120)
      const gravity = applyGravityAndFill(board)
      const flags = makeFlagMap(gravity.movedIndexes, 'falling')
      const createdIndexes = gravity.createdIndexes
      createdIndexes.forEach((index) => {
        flags[index] = 'new-tile'
      })
      this.setData({
        board: decorateBoard(board, null, flags),
        comboText: String(comboCount)
      })
      await sleep(ANIMATION_DELAY.fall)
    }

    return {
      board,
      comboCount,
    }
  },

  async detonateSpecialsAnimated(board, startIndex) {
    const queue = [startIndex]
    const visited = new Set()
    let chain = 0
    let damage = 0
    let scoreGain = 0

    while (queue.length) {
      const index = queue.shift()
      if (visited.has(index)) continue
      const tile = board[index]
      if (!tile || !tile.special) continue

      visited.add(index)
      chain += 1
      const hitDamage = chain * SPECIAL_DAMAGE
      const hitScore = chain * 520
      damage += hitDamage
      scoreGain += hitScore
      this.setData({
        board: decorateBoard(board, null, makeFlagMap([index], 'detonating')),
        comboText: String(chain)
      })
      await sleep(ANIMATION_DELAY.detonate)
      this.applyImmediateSettlement({ physical: hitDamage, magic: 0, heal: 0, spirit: 0 }, hitScore, chain, ['特殊连爆第' + chain + '枚'])
      board[index] = null

      const pos = indexToPos(index)
      for (let row = pos.row - 1; row <= pos.row + 1; row += 1) {
        for (let col = pos.col - 1; col <= pos.col + 1; col += 1) {
          if (row < 0 || row >= ROWS || col < 0 || col >= COLS) continue
          const next = posToIndex(row, col)
          if (!visited.has(next) && board[next] && board[next].special) {
            queue.push(next)
          }
        }
      }
      this.setData({
        board: decorateBoard(board, null)
      })
      await sleep(90)
    }

    const gravity = applyGravityAndFill(board)
    const flags = makeFlagMap(gravity.movedIndexes, 'falling')
    const createdIndexes = gravity.createdIndexes
    createdIndexes.forEach((index) => {
      flags[index] = 'new-tile'
    })
    this.setData({
      board: decorateBoard(board, null, flags)
    })
    await sleep(ANIMATION_DELAY.fall)
    return { board, damage, scoreGain, chain }
  },

  applyImmediateSettlement(effects, scoreGain, comboCount, notes) {
    let playerHp = Math.min(PLAYER_MAX_HP, this.data.playerHp + effects.heal)
    let playerSpirit = Math.min(PLAYER_MAX_SPIRIT, this.data.playerSpirit + effects.spirit)
    let npcHp = this.data.npcHp - effects.physical - effects.magic
    let score = this.data.score + scoreGain + comboCount * 60
    let gameOverState = this.evaluateGameOver(playerHp, npcHp, score)
    if (gameOverState.gameOver && gameOverState.resultTitle === '胜利') {
      score += 2000
      gameOverState = this.evaluateGameOver(playerHp, npcHp, score)
    }

    const parts = []
    if (effects.physical) parts.push('物伤' + effects.physical)
    if (effects.magic) parts.push('魔伤' + effects.magic)
    if (effects.heal) parts.push('回血' + effects.heal)
    if (effects.spirit) parts.push('精神' + effects.spirit)
    if (scoreGain) parts.push('分数+' + scoreGain)
    if (notes && notes.length) parts.push(notes.join('、'))

    this.setData({
      playerHp,
      playerSpirit,
      npcHp,
      score,
      playerHpPercent: percent(playerHp, PLAYER_MAX_HP),
      playerSpiritPercent: percent(playerSpirit, PLAYER_MAX_SPIRIT),
      npcHpPercent: percent(npcHp, NPC_MAX_HP),
      comboText: String(comboCount),
      settlementText: parts.join(' / '),
      gameOver: gameOverState.gameOver,
      resultTitle: gameOverState.resultTitle,
      resultGrade: gameOverState.resultGrade
    })
  },

  finishPlayerAction(board, comboCount) {
    let playerHp = this.data.playerHp
    let playerSpirit = this.data.playerSpirit
    let npcHp = this.data.npcHp
    let score = this.data.score - 50
    let settlementText = (this.data.settlementText || '') + ' / ' + comboCount + '连锁 / 回合分-50'
    let gameOverState = this.evaluateGameOver(playerHp, npcHp, score)
    if (gameOverState.gameOver && gameOverState.resultTitle === '胜利') {
      score += 2000
      gameOverState = this.evaluateGameOver(playerHp, npcHp, score)
    }
    let npcCountdown = this.data.npcCountdown
    let npcSkillIndex = this.data.npcSkillIndex

    if (!gameOverState.gameOver) {
      npcCountdown -= 1
      if (npcCountdown <= 0) {
        const npcResult = this.castNpcSkill(board, playerHp, npcHp, npcSkillIndex)
        playerHp = npcResult.playerHp
        npcHp = npcResult.npcHp
        npcSkillIndex = npcResult.npcSkillIndex
        settlementText += ' / ' + npcResult.text
        npcCountdown = NPC_SKILL_INTERVAL
        gameOverState = this.evaluateGameOver(playerHp, npcHp, score)
      }
    }
    if (!gameOverState.gameOver && ensureAvailableMove(board)) {
      settlementText += ' / 棋盘重整出新走法'
    }

    const skills = this.data.skills.map((skill) => Object.assign({}, skill, {
      remainingCooldown: Math.max(0, skill.remainingCooldown - 1)
    }))

    this.setData({
      board: decorateBoard(board, null),
      selectedIndex: null,
      playerHp,
      playerSpirit,
      npcHp,
      playerHpPercent: percent(playerHp, PLAYER_MAX_HP),
      playerSpiritPercent: percent(playerSpirit, PLAYER_MAX_SPIRIT),
      npcHpPercent: percent(npcHp, NPC_MAX_HP),
      turn: this.data.turn + 1,
      npcCountdown,
      npcSkillIndex,
      score,
      comboText: String(comboCount),
      skills: buildSkillsView(skills, playerSpirit, gameOverState.gameOver),
      npcSkills: buildNpcSkillsView(npcSkillIndex),
      settlementText,
      gameOver: gameOverState.gameOver,
      isAnimating: false,
      resultTitle: gameOverState.resultTitle,
      resultGrade: gameOverState.resultGrade
    })
  },

  castNpcSkill(board, playerHp, npcHp, npcSkillIndex) {
    const skill = npcSkillIndex % 3
    if (skill === 0) {
      return {
        playerHp: playerHp - 300,
        npcHp,
        npcSkillIndex: npcSkillIndex + 1,
        text: 'NPC暗刃：玩家受到300伤害'
      }
    }
    if (skill === 1) {
      return {
        playerHp,
        npcHp: Math.min(NPC_MAX_HP, npcHp + 450),
        npcSkillIndex: npcSkillIndex + 1,
        text: 'NPC汲取：NPC回复450生命'
      }
    }

    const indexes = pickRandomIndexes(getMutableIndexes(board), 4)
    indexes.forEach((index) => {
      board[index] = makeObstacleTile()
    })
    return {
      playerHp,
      npcHp,
      npcSkillIndex: npcSkillIndex + 1,
      text: 'NPC障壁：制造' + indexes.length + '个障碍'
    }
  },

  evaluateGameOver(playerHp, npcHp, score) {
    if (npcHp <= 0) {
      const grade = this.calculateGrade(score)
      return {
        gameOver: true,
        resultTitle: '胜利',
        resultGrade: grade
      }
    }
    if (playerHp <= 0) {
      return {
        gameOver: true,
        resultTitle: '失败',
        resultGrade: 'D'
      }
    }
    return {
      gameOver: false,
      resultTitle: '',
      resultGrade: ''
    }
  },

  calculateGrade(score) {
    if (score >= 9000) return 'S'
    if (score >= 6500) return 'A'
    if (score >= 4200) return 'B'
    return 'C'
  }
})
