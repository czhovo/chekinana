const {
  getLocalIdolRecords,
  getLocalCalendarRecords,
  saveLocalCalendarRecords,
  deleteLocalCalendarRecord
} = require('../../utils/local-user-data')

const WEEKDAYS = ['日', '一', '二', '三', '四', '五', '六']
const MIN_PICKER_MONTH = '1970-01'
const MAX_PICKER_MONTH = '2099-12'
const SWIPE_THRESHOLD = 60
const RECORD_TYPES = ['cheki', 'syame', 'douga']

function padNumber(value) {
  return value < 10 ? `0${value}` : `${value}`
}

function getDateKey(year, month, day) {
  return `${year}-${padNumber(month + 1)}-${padNumber(day)}`
}

function getPickerValue(year, month) {
  return `${year}-${padNumber(month + 1)}`
}

function getDisplayDateText(year, month, day) {
  return `${year}年${month + 1}月${day}日`
}

function getDaysInMonth(year, month) {
  return new Date(year, month + 1, 0).getDate()
}

function createDateCell(year, month, day, isCurrentMonth, selectedDateKey) {
  const dateKey = getDateKey(year, month, day)
  return {
    year,
    month,
    day,
    dateKey,
    isCurrentMonth,
    isSelected: dateKey === selectedDateKey
  }
}

function createCalendarWeeks(year, month, selectedDateKey) {
  const firstWeekday = new Date(year, month, 1).getDay()
  const daysInCurrentMonth = getDaysInMonth(year, month)
  const visibleRows = Math.ceil((firstWeekday + daysInCurrentMonth) / 7)
  const visibleCellCount = visibleRows * 7
  const weeks = []
  const cells = []
  const previousMonth = month - 1
  const previousMonthYear = previousMonth < 0 ? year - 1 : year
  const previousMonthIndex = previousMonth < 0 ? 11 : previousMonth
  const previousMonthDays = getDaysInMonth(previousMonthYear, previousMonthIndex)

  for (let index = 0; index < visibleCellCount; index += 1) {
    const cellDay = index - firstWeekday + 1
    if (cellDay < 1) {
      cells.push(createDateCell(previousMonthYear, previousMonthIndex, previousMonthDays + cellDay, false, selectedDateKey))
    } else if (cellDay > daysInCurrentMonth) {
      const nextMonth = month + 1
      const nextMonthYear = nextMonth > 11 ? year + 1 : year
      const nextMonthIndex = nextMonth > 11 ? 0 : nextMonth
      cells.push(createDateCell(nextMonthYear, nextMonthIndex, cellDay - daysInCurrentMonth, false, selectedDateKey))
    } else {
      cells.push(createDateCell(year, month, cellDay, true, selectedDateKey))
    }
  }

  for (let rowIndex = 0; rowIndex < visibleRows; rowIndex += 1) {
    weeks.push(cells.slice(rowIndex * 7, rowIndex * 7 + 7))
  }
  return weeks
}

function createCalendarState(displayYear, displayMonth, selectedYear, selectedMonth, selectedDay) {
  const selectedDateKey = getDateKey(selectedYear, selectedMonth, selectedDay)
  return {
    displayYear,
    displayMonth,
    selectedYear,
    selectedMonth,
    selectedDay,
    selectedDateKey,
    selectedDateText: getDisplayDateText(selectedYear, selectedMonth, selectedDay),
    pickerValue: getPickerValue(displayYear, displayMonth),
    monthTitle: `${displayYear}年${displayMonth + 1}月`,
    weeks: createCalendarWeeks(displayYear, displayMonth, selectedDateKey)
  }
}

function normalizeColorList(value) {
  if (!Array.isArray(value)) return []
  return value.filter((item) => /^#[0-9a-f]{6}$/i.test(String(item || '').trim()))
}

function buildColorRingStyle(colors) {
  const list = normalizeColorList(colors)
  if (!list.length) return 'background: #d9dde5;'
  if (list.length === 1) return `background: ${list[0]};`
  const step = 360 / list.length
  const segments = list.map((color, index) => {
    const start = Math.round(step * index * 100) / 100
    const end = Math.round(step * (index + 1) * 100) / 100
    return `${color} ${start}deg ${end}deg`
  })
  return `background: conic-gradient(${segments.join(', ')});`
}

function firstValue() {
  for (let i = 0; i < arguments.length; i += 1) {
    const value = arguments[i]
    if (value !== undefined && value !== null && String(value).trim()) return String(value).trim()
  }
  return ''
}

function normalizeIdolRecord(record) {
  if (!record || typeof record !== 'object') return null
  const avatarUrl = firstValue(record.avatarDisplayUrl, record.avatarUrl, record.avatarPublicUrl, record.avatarDataUrl)
  const colors = normalizeColorList(record.colors)
  return {
    id: firstValue(record.id, record.recordId, record.record_id),
    idolName: firstValue(record.idolName, record.idol_name, record.name),
    groupName: firstValue(record.groupName, record.group_name, record.group),
    avatarUrl,
    colors,
    colorRingStyle: buildColorRingStyle(colors)
  }
}

function normalizeCalendarRecord(record) {
  if (!record || typeof record !== 'object') return null
  const id = firstValue(record.id)
  const date = firstValue(record.date)
  if (!id || !date) return null
  const quantity = Math.max(1, Number(record.quantity) || 1)
  const idolSnapshots = Array.isArray(record.idolSnapshots) ? record.idolSnapshots : []
  return {
    id,
    date,
    type: RECORD_TYPES.indexOf(record.type) >= 0 ? record.type : 'cheki',
    quantity,
    idolIds: Array.isArray(record.idolIds) ? record.idolIds.map(String) : [],
    idolSnapshots: idolSnapshots.map(normalizeIdolRecord).filter(Boolean),
    note: firstValue(record.note),
    extra: record.extra && typeof record.extra === 'object' ? record.extra : {},
    createdAt: firstValue(record.createdAt),
    updatedAt: firstValue(record.updatedAt)
  }
}

function createCalendarRecordId() {
  return `calendar_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`
}

Page({
  data: {
    weekdays: WEEKDAYS,
    minPickerMonth: MIN_PICKER_MONTH,
    maxPickerMonth: MAX_PICKER_MONTH,
    pickerValue: '',
    monthTitle: '',
    displayYear: 0,
    displayMonth: 0,
    selectedYear: 0,
    selectedMonth: 0,
    selectedDay: 0,
    selectedDateKey: '',
    selectedDateText: '',
    weeks: [],
    selectedDateRecords: [],
    recordTypes: RECORD_TYPES,
    showRecordDialog: false,
    recordDialogMode: 'create',
    recordDialogTitle: 'Add Record',
    editingRecordId: '',
    recordTypeIndex: 0,
    recordQuantity: '1',
    recordNote: '',
    recordSelectedIdols: [],
    availableIdols: [],
    showIdolPicker: false,
    showRecordDetail: false,
    detailRecord: null
  },

  touchStartX: 0,
  touchStartY: 0,

  onLoad() {
    const today = new Date()
    this.setData(createCalendarState(
      today.getFullYear(),
      today.getMonth(),
      today.getFullYear(),
      today.getMonth(),
      today.getDate()
    ))
    this.refreshSelectedDateRecords()
  },

  onShow() {
    this.setTabBarSelected(1)
    if (this.data.selectedDateKey) this.refreshSelectedDateRecords()
  },

  setTabBarSelected(selected) {
    if (typeof this.getTabBar !== 'function') return
    const tabBar = this.getTabBar()
    if (tabBar) tabBar.setData({ selected })
  },

  showPreviousMonth() {
    this.changeMonth(-1)
  },

  showNextMonth() {
    this.changeMonth(1)
  },

  changeMonth(offset) {
    const nextDate = new Date(this.data.displayYear, this.data.displayMonth + offset, 1)
    this.setData(createCalendarState(
      nextDate.getFullYear(),
      nextDate.getMonth(),
      this.data.selectedYear,
      this.data.selectedMonth,
      this.data.selectedDay
    ))
  },

  onMonthPickerChange(event) {
    const value = event.detail.value
    const parts = value.split('-')
    const year = Number(parts[0])
    const month = Number(parts[1]) - 1
    if (!Number.isFinite(year) || !Number.isFinite(month)) return
    this.setData(createCalendarState(
      year,
      month,
      this.data.selectedYear,
      this.data.selectedMonth,
      this.data.selectedDay
    ))
  },

  onDateTap(event) {
    const year = Number(event.currentTarget.dataset.year)
    const month = Number(event.currentTarget.dataset.month)
    const day = Number(event.currentTarget.dataset.day)
    if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) return
    this.setData(createCalendarState(
      this.data.displayYear,
      this.data.displayMonth,
      year,
      month,
      day
    ))
    this.refreshSelectedDateRecords()
  },

  onCalendarTouchStart(event) {
    const touch = event.changedTouches[0]
    this.touchStartX = touch.clientX
    this.touchStartY = touch.clientY
  },

  onCalendarTouchEnd(event) {
    const touch = event.changedTouches[0]
    const deltaX = touch.clientX - this.touchStartX
    const deltaY = touch.clientY - this.touchStartY
    if (Math.abs(deltaX) < SWIPE_THRESHOLD || Math.abs(deltaX) <= Math.abs(deltaY)) return
    if (deltaX < 0) {
      this.showNextMonth()
    } else {
      this.showPreviousMonth()
    }
  },

  getAllCalendarRecords() {
    return getLocalCalendarRecords().map(normalizeCalendarRecord).filter(Boolean)
  },

  refreshSelectedDateRecords() {
    const date = this.data.selectedDateKey
    const records = this.getAllCalendarRecords()
      .filter((record) => record.date === date)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))
    this.setData({ selectedDateRecords: records })
  },

  loadAvailableIdols(selectedIds) {
    const selected = {}
    ;(selectedIds || []).forEach((id) => {
      selected[String(id)] = true
    })
    const idols = getLocalIdolRecords().map(normalizeIdolRecord).filter((idol) => idol && idol.id)
    return idols.map((idol) => Object.assign({}, idol, {
      selected: !!selected[String(idol.id)]
    }))
  },

  openAddRecordDialog() {
    if (!this.data.selectedDateKey) {
      wx.showToast({ title: '请先选择日期', icon: 'none' })
      return
    }
    this.setData({
      showRecordDialog: true,
      recordDialogMode: 'create',
      recordDialogTitle: 'Add Record',
      editingRecordId: '',
      recordTypeIndex: 0,
      recordQuantity: '1',
      recordNote: '',
      recordSelectedIdols: [],
      availableIdols: this.loadAvailableIdols([]),
      showRecordDetail: false
    })
  },

  openRecordDetail(event) {
    const recordId = event.currentTarget.dataset.recordId
    const record = this.findCalendarRecord(recordId)
    if (!record) return
    this.setData({
      showRecordDetail: true,
      detailRecord: record
    })
  },

  closeRecordDetail() {
    this.setData({
      showRecordDetail: false,
      detailRecord: null
    })
  },

  modifyDetailRecord() {
    const record = this.data.detailRecord
    if (!record) return
    this.openRecordDialogForRecord(record)
  },

  openRecordDialogForRecord(record) {
    const typeIndex = Math.max(0, RECORD_TYPES.indexOf(record.type))
    this.setData({
      showRecordDialog: true,
      recordDialogMode: 'modify',
      recordDialogTitle: 'Modify Record',
      editingRecordId: record.id,
      recordTypeIndex: typeIndex,
      recordQuantity: String(record.quantity || 1),
      recordNote: record.note || '',
      recordSelectedIdols: record.idolSnapshots || [],
      availableIdols: this.loadAvailableIdols(record.idolIds || []),
      showRecordDetail: false,
      detailRecord: null
    })
  },

  closeRecordDialog() {
    this.setData({
      showRecordDialog: false,
      showIdolPicker: false
    })
  },

  onRecordTypeChange(event) {
    const index = Number(event.detail.value)
    this.setData({ recordTypeIndex: Number.isFinite(index) ? index : 0 })
  },

  onRecordQuantityInput(event) {
    this.setData({ recordQuantity: event.detail.value || '' })
  },

  onRecordNoteInput(event) {
    this.setData({ recordNote: event.detail.value || '' })
  },

  openIdolPicker() {
    this.setData({ showIdolPicker: true })
  },

  closeIdolPicker() {
    this.setData({ showIdolPicker: false })
  },

  toggleIdolSelection(event) {
    const idolId = String(event.currentTarget.dataset.idolId || '')
    if (!idolId) return
    const availableIdols = (this.data.availableIdols || []).map((idol) => {
      if (String(idol.id) !== idolId) return idol
      return Object.assign({}, idol, { selected: !idol.selected })
    })
    this.setData({ availableIdols })
  },

  confirmIdolSelection() {
    const selected = (this.data.availableIdols || [])
      .filter((idol) => idol.selected)
      .map((idol) => this.createIdolSnapshot(idol))
    this.setData({
      recordSelectedIdols: selected,
      showIdolPicker: false
    })
  },

  removeSelectedIdol(event) {
    const idolId = String(event.currentTarget.dataset.idolId || '')
    const recordSelectedIdols = (this.data.recordSelectedIdols || []).filter((idol) => String(idol.id) !== idolId)
    const availableIdols = (this.data.availableIdols || []).map((idol) => {
      if (String(idol.id) !== idolId) return idol
      return Object.assign({}, idol, { selected: false })
    })
    this.setData({
      recordSelectedIdols,
      availableIdols
    })
  },

  createIdolSnapshot(idol) {
    const colors = normalizeColorList(idol.colors)
    return {
      id: idol.id,
      idolName: idol.idolName || '',
      groupName: idol.groupName || '',
      avatarUrl: idol.avatarUrl || '',
      colors,
      colorRingStyle: buildColorRingStyle(colors)
    }
  },

  saveRecordDialog() {
    if (!this.data.selectedDateKey) {
      wx.showToast({ title: '请先选择日期', icon: 'none' })
      return
    }
    const quantity = Number(this.data.recordQuantity)
    if (!Number.isInteger(quantity) || quantity <= 0) {
      wx.showToast({ title: '数量必须为正整数', icon: 'none' })
      return
    }

    const now = new Date().toISOString()
    const records = getLocalCalendarRecords()
    const isModify = this.data.recordDialogMode === 'modify' && this.data.editingRecordId
    const recordId = isModify ? String(this.data.editingRecordId) : createCalendarRecordId()
    const existingIndex = records.findIndex((record) => String(record && record.id) === recordId)
    const existing = existingIndex >= 0 ? records[existingIndex] : {}
    const idolSnapshots = (this.data.recordSelectedIdols || []).map((idol) => this.createIdolSnapshot(idol))
    const nextRecord = {
      id: recordId,
      date: this.data.selectedDateKey,
      type: RECORD_TYPES[this.data.recordTypeIndex] || 'cheki',
      quantity,
      idolIds: idolSnapshots.map((idol) => idol.id),
      idolSnapshots,
      note: String(this.data.recordNote || '').trim(),
      extra: existing.extra && typeof existing.extra === 'object' ? existing.extra : {},
      createdAt: existing.createdAt || now,
      updatedAt: now
    }

    if (existingIndex >= 0) {
      records[existingIndex] = nextRecord
    } else {
      records.unshift(nextRecord)
    }
    saveLocalCalendarRecords(records)
    this.setData({
      showRecordDialog: false,
      showIdolPicker: false
    })
    this.refreshSelectedDateRecords()
  },

  deleteDetailRecord() {
    const record = this.data.detailRecord
    if (!record) return
    wx.showModal({
      title: 'Delete Record',
      content: `Delete ${record.type} x${record.quantity}?`,
      confirmText: 'Delete',
      confirmColor: '#ef4444',
      cancelText: 'Cancel',
      success: (res) => {
        if (!res.confirm) return
        deleteLocalCalendarRecord(record.id)
        this.setData({
          showRecordDetail: false,
          detailRecord: null
        })
        this.refreshSelectedDateRecords()
      }
    })
  },

  findCalendarRecord(recordId) {
    const id = String(recordId || '')
    if (!id) return null
    return this.getAllCalendarRecords().find((record) => String(record.id) === id) || null
  },

  noop() {}
})
