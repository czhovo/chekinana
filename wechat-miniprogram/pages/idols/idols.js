const {
  AUTH_STORAGE_KEY,
  API_GATEWAY_BASE_URL
} = require('../../utils/config')
const {
  getLocalIdolRecords,
  saveLocalIdolRecords,
  deleteLocalIdolRecord
} = require('../../utils/local-user-data')

const WEIBO_PROFILE_ENDPOINT = 'https://chekinana.top/api/weibo-profile'
const IDOL_COLOR_PRESETS = [
  { label: '红', value: '#ef4444' },
  { label: '橙', value: '#f97316' },
  { label: '黄', value: '#facc15' },
  { label: '绿', value: '#22c55e' },
  { label: '浅蓝', value: '#38bdf8' },
  { label: '深蓝', value: '#2563eb' },
  { label: '紫', value: '#8b5cf6' },
  { label: '粉', value: '#ec4899' },
  { label: '白', value: '#d9d9d9' }
]
const IDOL_MAX_CUSTOM_COLORS = 6

function normalizeHexColor(value) {
  const raw = String(value || '').trim()
  if (!raw) return ''
  if (/^#[0-9a-f]{6}$/i.test(raw)) return raw.toLowerCase()
  const short = raw.match(/^#([0-9a-f])([0-9a-f])([0-9a-f])$/i)
  if (short) return `#${short[1]}${short[1]}${short[2]}${short[2]}${short[3]}${short[3]}`.toLowerCase()
  return ''
}

function normalizeColorList(value) {
  let raw = value
  if (typeof raw === 'string') {
    try {
      raw = JSON.parse(raw)
    } catch (e) {
      raw = raw.split(',')
    }
  }
  if (!Array.isArray(raw)) return []

  const seen = {}
  const colors = []
  raw.forEach((item) => {
    const color = normalizeHexColor(item && item.value ? item.value : item)
    if (!color || seen[color]) return
    seen[color] = true
    colors.push(color)
  })
  return colors
}

function normalizeWeiboUrl(value) {
  const raw = String(value || '').trim()
  if (!raw) return ''
  return /^https?:\/\//i.test(raw) ? raw : `https://${raw}`
}

function getHost(url) {
  const match = String(url || '').match(/^https?:\/\/([^/?#]+)/i)
  return match ? match[1].toLowerCase() : ''
}

function isWeiboHost(host) {
  return /(^|\.)weibo\.com$/.test(host) || /(^|\.)m\.weibo\.cn$/.test(host)
}

function request(options) {
  return new Promise((resolve, reject) => {
    wx.request(Object.assign({}, options, {
      success: (res) => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(res)
          return
        }

        const data = parseMaybeJson(res.data)
        const error = new Error(getErrorMessage(data) || `HTTP ${res.statusCode || 'unknown'}`)
        error.statusCode = res.statusCode
        error.data = data
        reject(error)
      },
      fail: (err) => {
        reject(new Error(err && err.errMsg ? err.errMsg : 'request failed'))
      }
    }))
  })
}

function parseMaybeJson(data) {
  if (typeof data !== 'string') return data
  try {
    return JSON.parse(data)
  } catch (e) {
    return data
  }
}

function getErrorMessage(data) {
  if (!data) return ''
  if (typeof data === 'string') return data
  return displayValue(data.message || data.error || data.errorMessage || '')
}

function firstValue() {
  for (let i = 0; i < arguments.length; i++) {
    const value = arguments[i]
    if (value !== undefined && value !== null && String(value).trim()) return value
  }
  return ''
}

function displayValue(value) {
  if (value === undefined || value === null) return ''
  if (Array.isArray(value)) {
    return value.map(displayValue).filter(Boolean).join('\n')
  }
  if (typeof value !== 'object') return String(value).trim()

  const orderedKeys = [
    'reason',
    'type',
    'status',
    'message',
    'name',
    'text',
    'content',
    'createdAt',
    'created_at',
    'source',
    'url'
  ]
  const seen = {}
  const lines = []

  orderedKeys.forEach((key) => {
    if (value[key] === undefined || value[key] === null) return
    const text = displayValue(value[key])
    if (!text) return
    seen[key] = true
    lines.push(`${key}: ${text}`)
  })

  Object.keys(value).forEach((key) => {
    if (seen[key] || value[key] === undefined || value[key] === null) return
    const text = displayValue(value[key])
    if (!text) return
    lines.push(`${key}: ${text}`)
  })

  return lines.join('\n')
}

function displayVerification(value) {
  if (value === undefined || value === null) return ''
  if (typeof value !== 'object') return displayValue(value)

  const verifiedDetail = value.verified_detail || value.verifiedDetail || {}
  const detailData = Array.isArray(verifiedDetail.data) ? verifiedDetail.data : []
  const directData = Array.isArray(value.data) ? value.data : []

  return firstValue(
    value.reason,
    value.desc,
    value.description,
    value.text,
    detailData[0] && detailData[0].desc,
    directData[0] && directData[0].desc,
    displayValue(value)
  )
}

function createColorOptions(selectedColors) {
  const selected = normalizeColorList(selectedColors)
  const selectedMap = {}
  selected.forEach((color) => {
    selectedMap[color] = true
  })
  const presetMap = {}
  const options = IDOL_COLOR_PRESETS.map((color, index) => ({
    id: `preset-${index}`,
    label: color.label,
    value: color.value,
    selected: !!selectedMap[normalizeHexColor(color.value)],
    isOther: false
  }))
  IDOL_COLOR_PRESETS.forEach((color) => {
    presetMap[normalizeHexColor(color.value)] = true
  })
  const customColors = selected.filter((color) => !presetMap[color]).slice(0, IDOL_MAX_CUSTOM_COLORS)
  customColors.forEach((color, index) => {
    options.push({
      id: `custom-${index + 1}`,
      label: color,
      value: color,
      selected: true,
      isOther: false
    })
  })
  if (customColors.length < IDOL_MAX_CUSTOM_COLORS) {
    options.push(createOtherColorOption(customColors.length))
  }
  return options
}

function createOtherColorOption(index) {
  return {
    id: `other-${index}`,
    label: 'Other',
    value: '',
    selected: false,
    isOther: true
  }
}

function clampRgb(value) {
  const number = Number(value)
  if (!Number.isFinite(number)) return 0
  return Math.max(0, Math.min(255, Math.round(number)))
}

function toHexChannel(value) {
  return clampRgb(value).toString(16).padStart(2, '0')
}

function rgbToHex(color) {
  return `#${toHexChannel(color.r)}${toHexChannel(color.g)}${toHexChannel(color.b)}`
}

function isLocalAvatarPath(value) {
  const raw = String(value || '').trim()
  return !!raw && !/^https?:\/\//i.test(raw) && !isDataAvatarUrl(raw)
}

function isDataAvatarUrl(value) {
  return /^data:image\/[a-z0-9.+-]+;base64,/i.test(String(value || '').trim())
}

function getDataAvatarContentType(value) {
  const match = String(value || '').trim().match(/^data:(image\/[a-z0-9.+-]+);base64,/i)
  return match ? match[1].toLowerCase() : 'image/jpeg'
}

function inferImageContentType(filePath) {
  const path = String(filePath || '').split(/[?#]/)[0].toLowerCase()
  if (path.endsWith('.png')) return 'image/png'
  if (path.endsWith('.webp')) return 'image/webp'
  if (path.endsWith('.gif')) return 'image/gif'
  if (path.endsWith('.bmp')) return 'image/bmp'
  return 'image/jpeg'
}

function resolveApiUrl(value) {
  const raw = String(value || '').trim()
  if (!raw) return ''
  if (/^https?:\/\//i.test(raw)) return raw
  return `${API_GATEWAY_BASE_URL}${raw.charAt(0) === '/' ? raw : `/${raw}`}`
}

function isProtectedAvatarUrl(value) {
  const raw = String(value || '').trim()
  if (!raw) return false
  if (raw.charAt(0) === '/') return true
  return /^https:\/\/api\.chekinana\.top\//i.test(raw)
}

function isTrustedPublicAvatarUrl(value) {
  const raw = String(value || '').trim()
  if (!/^https?:\/\//i.test(raw)) return false
  return getHost(raw) === 'chekinana.top'
}

function firstTrustedPublicAvatarUrl() {
  for (let i = 0; i < arguments.length; i++) {
    const value = firstValue(arguments[i])
    if (value && isTrustedPublicAvatarUrl(value)) return value
  }
  return ''
}

function getRecordId(record) {
  return firstValue(record.id, record.recordId, record.record_id, record.uuid)
}

function createLocalIdolRecordId() {
  return `idol_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`
}

function normalizeIdolRecord(record) {
  const payload = record && record.record ? record.record : record
  if (!payload || typeof payload !== 'object') return null

  const avatar = payload.avatar && typeof payload.avatar === 'object' ? payload.avatar : {}
  const id = getRecordId(payload)
  const colors = normalizeColorList(firstValue(
    payload.colors,
    payload.selectedColors,
    payload.selected_colors,
    payload.colorList,
    payload.color_list
  ))

  return {
    id,
    idolName: firstValue(payload.idolName, payload.idol_name, payload.name),
    groupName: firstValue(payload.groupName, payload.group_name, payload.group),
    avatarUrl: firstValue(
      payload.avatarUrl,
      payload.avatar_url,
      typeof payload.avatar === 'string' ? payload.avatar : '',
      avatar.url,
      avatar.publicUrl,
      avatar.public_url,
      payload.avatarPublicUrl,
      payload.avatar_public_url,
      payload.avatarDataUrl,
      payload.avatar_data_url
    ),
    avatarKind: firstValue(payload.avatarKind, payload.avatar_kind, avatar.kind),
    avatarPublicUrl: firstValue(payload.avatarPublicUrl, payload.avatar_public_url, avatar.publicUrl, avatar.public_url),
    avatarDataUrl: firstValue(payload.avatarDataUrl, payload.avatar_data_url, avatar.dataUrl, avatar.data_url),
    avatarContentType: firstValue(payload.avatarContentType, payload.avatar_content_type, avatar.contentType, avatar.content_type),
    avatarDisplayUrl: '',
    colors,
    colorRingStyle: buildColorRingStyle(colors),
    weiboUid: firstValue(payload.weiboUid, payload.weibo_uid, payload.uid),
    weiboUsername: firstValue(payload.weiboUsername, payload.weibo_username, payload.username),
    weiboVerification: firstValue(payload.weiboVerification, payload.weibo_verification, payload.verification),
    raw: payload
  }
}

function normalizeIdolRecords(data) {
  const payload = data && data.data ? data.data : data
  const list = Array.isArray(payload)
    ? payload
    : (payload && (payload.records || payload.idols || payload.items || payload.list)) || []
  return list.map(normalizeIdolRecord).filter((record) => record && record.id)
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

function sameText(a, b) {
  return String(a || '').trim() === String(b || '').trim()
}

function normalizeWorkerProfile(data) {
  const payload = data && data.data ? data.data : data
  const profile = payload && payload.profile ? payload.profile : payload
  const avatar = payload && payload.avatar ? payload.avatar : {}
  const avatarStorage = avatar && avatar.storage ? avatar.storage : {}
  const profileAvatar = profile && profile.avatar && typeof profile.avatar === 'object' ? profile.avatar : {}
  const profileAvatarStorage = profileAvatar && profileAvatar.storage ? profileAvatar.storage : {}

  if (!profile || typeof profile !== 'object') {
    throw new Error('查询结果为空')
  }

  const trustedAvatarUrl = firstTrustedPublicAvatarUrl(
    payload.avatarUrl,
    payload.avatar_url,
    avatarStorage.avatarUrl,
    avatarStorage.avatar_url,
    avatarStorage.publicUrl,
    avatarStorage.public_url,
    avatarStorage.url,
    profileAvatarStorage.avatarUrl,
    profileAvatarStorage.avatar_url,
    profileAvatarStorage.publicUrl,
    profileAvatarStorage.public_url,
    profileAvatarStorage.url,
    avatar.publicUrl,
    avatar.public_url,
    profileAvatar.publicUrl,
    profileAvatar.public_url
  )
  const sourceAvatarUrl = firstValue(
    profile.sourceAvatarUrl,
    profile.source_avatar_url,
    avatar.sourceUrl,
    avatar.source_url,
    profileAvatar.sourceUrl,
    profileAvatar.source_url,
    profile.avatarUrl,
    profile.avatar_url,
    profileAvatar.url,
    profileAvatar.avatarUrl,
    typeof profile.avatar === 'string' ? profile.avatar : '',
    avatar.url
  )

  return {
    uid: firstValue(profile.uid, profile.id, profile.userId, payload.uid),
    username: firstValue(profile.username, profile.screenName, profile.screen_name, profile.name),
    avatarUrl: firstValue(trustedAvatarUrl, sourceAvatarUrl, payload.avatarUrl, payload.avatar_url),
    sourceAvatarUrl,
    verification: displayVerification(firstValue(profile.verification, profile.verifiedReason, profile.verified_reason)),
    avatarStatus: firstValue(
      payload.avatarStatus,
      payload.avatarStorageStatus,
      profile.avatarStatus,
      profile.avatar_storage_status,
      avatar.status,
      avatar.storageStatus,
      avatarStorage.status,
      avatar.exists === true ? '头像已存在' : '',
      avatar.uploaded === true ? '头像已保存' : ''
    ),
    rawFields: Array.isArray(payload.fields) ? payload.fields : []
  }
}

Page({
  data: {
    weiboUrl: '',
    loading: false,
    errorText: '',
    emptyText: '',
    statusText: '',
    statusKind: 'idle',
    profile: null,
    profileActionLabel: 'Add',
    profileMatchedRecordId: '',
    profileStoredRecords: [],
    fields: [],
    avatarStatus: '',
    idolRecords: [],
    idolRecordsLoading: false,
    idolRecordsStatusText: '',
    showIdolAddDialog: false,
    idolDialogTitle: 'Add Idol',
    idolAddMode: 'create',
    idolAddRecordId: '',
    idolAddWeiboUid: '',
    idolAddWeiboUsername: '',
    idolAddWeiboVerification: '',
    idolAddAvatarUrl: '',
    idolAddName: '',
    idolAddGroupName: '',
    idolAddColorOptions: createColorOptions(),
    idolAddCustomPanelOpen: false,
    idolAddCustomColor: {
      r: 37,
      g: 99,
      b: 235
    },
    idolAddNextCustomColorId: 1,
    idolAddSaving: false
  },

  onShow() {
    this.setTabBarSelected(2)
    this.loadIdolRecords()
  },

  setTabBarSelected(selected) {
    if (typeof this.getTabBar !== 'function') return
    const tabBar = this.getTabBar()
    if (tabBar) tabBar.setData({ selected })
  },

  onWeiboUrlInput(e) {
    this.setData({
      weiboUrl: e.detail.value,
      errorText: '',
      emptyText: '',
      statusText: '',
      statusKind: 'idle'
    })
  },

  async onQueryTap() {
    if (this.data.loading) return

    const profileUrl = normalizeWeiboUrl(this.data.weiboUrl)
    this.setData({
      statusText: '',
      statusKind: 'idle'
    })

    const host = getHost(profileUrl)
    if (!profileUrl || !isWeiboHost(host)) {
      this.setData({
        errorText: '请输入有效的微博主页链接',
        emptyText: '',
        statusText: '链接校验失败',
        statusKind: 'error',
        profile: null,
        profileActionLabel: 'Add',
        profileMatchedRecordId: '',
        profileStoredRecords: [],
        fields: [],
        avatarStatus: ''
      })
      return
    }

    this.setData({
      loading: true,
      errorText: '',
      emptyText: '',
      statusText: '',
      statusKind: 'idle',
      profile: null,
      profileActionLabel: 'Add',
      profileMatchedRecordId: '',
      profileStoredRecords: [],
      fields: [],
      avatarStatus: ''
    })

    try {
      const profile = await this.fetchWorkerProfile(profileUrl)
      const fields = this.buildFields(profile)
      const profileState = this.buildProfileRecordState(profile, this.data.idolRecords)

      this.setData({
        loading: false,
        profile: profile.uid || profile.username || profile.avatarUrl ? profile : null,
        profileActionLabel: profileState.actionLabel,
        profileMatchedRecordId: profileState.matchedRecordId,
        profileStoredRecords: profileState.storedRecords,
        fields,
        avatarStatus: profile.avatarStatus,
        showIdolAddDialog: false,
        emptyText: fields.length || profile.avatarUrl ? '' : '未提取到可显示的信息',
        statusText: '',
        statusKind: fields.length || profile.avatarUrl ? 'idle' : 'empty'
      })
    } catch (err) {
      console.warn('[weibo] worker lookup failed', err)
      this.setData({
        loading: false,
        errorText: err && err.message ? err.message : '查询失败',
        emptyText: '',
        statusText: '查询失败',
        statusKind: 'error',
        profile: null,
        profileActionLabel: 'Add',
        profileMatchedRecordId: '',
        profileStoredRecords: [],
        fields: [],
        avatarStatus: ''
      })
    }
  },

  loadIdolRecords() {
    this.setData({
      idolRecordsLoading: true,
      idolRecordsStatusText: ''
    })

    try {
      const records = this.prepareIdolRecordsForDisplay(normalizeIdolRecords(getLocalIdolRecords()))
      this.setData({
        idolRecords: records,
        idolRecordsLoading: false,
        idolRecordsStatusText: ''
      })
      this.refreshProfileRecordState(records)
      this.resolveProtectedIdolAvatars(records)
    } catch (err) {
      console.warn('[idols] load records failed', err)
      this.idolAvatarResolveRunId = (this.idolAvatarResolveRunId || 0) + 1
      this.setData({
        idolRecords: [],
        idolRecordsLoading: false,
        idolRecordsStatusText: '偶像记录加载失败'
      })
      this.refreshProfileRecordState([])
    }
  },

  prepareIdolRecordsForDisplay(records) {
    return (records || []).map((record) => {
      const avatarUrl = record.avatarUrl || ''
      return Object.assign({}, record, {
        avatarDisplayUrl: avatarUrl && !isProtectedAvatarUrl(avatarUrl) ? avatarUrl : ''
      })
    })
  },

  resolveProtectedIdolAvatars(records) {
    const protectedRecords = (records || []).filter((record) => {
      return record && record.id && record.avatarUrl && isProtectedAvatarUrl(record.avatarUrl)
    })
    if (!protectedRecords.length) return

    const runId = (this.idolAvatarResolveRunId || 0) + 1
    this.idolAvatarResolveRunId = runId
    this.idolAvatarCache = this.idolAvatarCache || {}

    protectedRecords.forEach((record) => {
      const sourceUrl = resolveApiUrl(record.avatarUrl)
      if (this.idolAvatarCache[sourceUrl]) {
        this.applyIdolAvatarDisplayUrl(record.id, this.idolAvatarCache[sourceUrl], runId)
        return
      }

      this.downloadProtectedIdolAvatar(sourceUrl).then((localPath) => {
        this.idolAvatarCache[sourceUrl] = localPath
        this.applyIdolAvatarDisplayUrl(record.id, localPath, runId)
      }).catch((err) => {
        console.warn('[idols] protected avatar download failed', err)
      })
    })
  },

  downloadProtectedIdolAvatar(url) {
    return new Promise((resolve, reject) => {
      wx.downloadFile({
        url,
        header: { Accept: 'image/*' },
        success: (res) => {
          if (res.statusCode >= 200 && res.statusCode < 300 && res.tempFilePath) {
            resolve(res.tempFilePath)
            return
          }
          const error = new Error(`avatar download HTTP ${res.statusCode || 'unknown'}`)
          error.statusCode = res.statusCode
          reject(error)
        },
        fail: (err) => {
          reject(new Error(err && err.errMsg ? err.errMsg : 'avatar download failed'))
        }
      })
    })
  },

  applyIdolAvatarDisplayUrl(recordId, localPath, runId) {
    if (runId && runId !== this.idolAvatarResolveRunId) return
    const id = String(recordId)
    const updateRecord = (record) => {
      if (!record || String(record.id) !== id) return record
      return Object.assign({}, record, { avatarDisplayUrl: localPath })
    }
    this.setData({
      idolRecords: (this.data.idolRecords || []).map(updateRecord),
      profileStoredRecords: (this.data.profileStoredRecords || []).map(updateRecord)
    })
  },

  refreshProfileRecordState(records) {
    if (!this.data.profile) return
    const profileState = this.buildProfileRecordState(this.data.profile, records)
    this.setData({
      profileActionLabel: profileState.actionLabel,
      profileMatchedRecordId: profileState.matchedRecordId,
      profileStoredRecords: profileState.storedRecords
    })
  },

  buildProfileRecordState(profile, records) {
    const uid = String(profile && profile.uid ? profile.uid : '').trim()
    if (!uid) {
      return {
        actionLabel: 'Add',
        matchedRecordId: '',
        storedRecords: []
      }
    }

    const sameUidRecords = (records || []).filter((record) => sameText(record.weiboUid, uid))
    const matchedRecord = sameUidRecords.find((record) => {
      return sameText(record.weiboUsername, profile.username)
        && sameText(record.weiboVerification, profile.verification)
    })
    const storedRecords = sameUidRecords.filter((record) => {
      return !sameText(record.weiboUsername, profile.username)
        || !sameText(record.weiboVerification, profile.verification)
    })

    return {
      actionLabel: matchedRecord ? 'Modify' : (sameUidRecords.length ? 'Add New' : 'Add'),
      matchedRecordId: matchedRecord ? matchedRecord.id : '',
      storedRecords
    }
  },

  async fetchWorkerProfile(profileUrl) {
    const token = wx.getStorageSync(AUTH_STORAGE_KEY) || ''
    const header = {
      Accept: 'application/json'
    }
    if (token) header['X-Cheki-Token'] = token

    const res = await request({
      url: `${WEIBO_PROFILE_ENDPOINT}?url=${encodeURIComponent(profileUrl)}`,
      method: 'GET',
      header
    })
    const data = parseMaybeJson(res.data)
    if (data && data.ok === false) {
      throw new Error(getErrorMessage(data) || '查询失败')
    }
    return normalizeWorkerProfile(data)
  },

  buildFields(profile) {
    const fields = []

    profile.rawFields.forEach((field) => {
      if (!field || typeof field !== 'object') return
      if (this.isPinnedWeiboField(field)) return
      if (this.isIntroField(field)) return
      if (this.isPrimaryProfileField(field)) return
      this.pushField(fields, field.label || field.name, field.value)
    })
    return fields
  },

  isPinnedWeiboField(field) {
    const key = String(field.key || field.name || field.label || '').toLowerCase()
    return key.includes('pinned')
      || key.includes('置顶')
      || key.includes('置頂')
  },

  isIntroField(field) {
    const key = String(field.key || field.name || field.label || '').toLowerCase()
    return key.includes('intro')
      || key.includes('description')
      || key.includes('bio')
      || key.includes('简介')
      || key.includes('介绍')
  },

  isPrimaryProfileField(field) {
    const key = String(field.key || field.name || field.label || '').toLowerCase()
    return key.includes('username')
      || key.includes('screenname')
      || key.includes('screen_name')
      || key.includes('name')
      || key.includes('用户名')
      || key.includes('微博认证')
      || key.includes('verification')
      || key.includes('verified')
      || key.includes('avatar')
      || key.includes('头像')
  },

  pushField(fields, label, value) {
    const text = displayValue(value)
    const title = String(label || '').trim()
    if (!title || !text) return
    fields.push({ label: title, value: text })
  },

  openIdolAddDialog(event) {
    const profile = this.data.profile || {}
    const recordId = event && event.currentTarget && event.currentTarget.dataset
      ? event.currentTarget.dataset.recordId
      : ''
    const matchedRecord = recordId ? this.findIdolRecord(recordId) : null
    this.openIdolDialogFromProfile(profile, matchedRecord)
  },

  openStoredIdolDialog(event) {
    const recordId = event && event.currentTarget && event.currentTarget.dataset
      ? event.currentTarget.dataset.recordId
      : ''
    const record = this.findIdolRecord(recordId)
    if (!record) return
    this.openIdolDialog({
      mode: 'modify',
      recordId: record.id,
      avatarUrl: record.avatarDisplayUrl || (isProtectedAvatarUrl(record.avatarUrl) ? '' : record.avatarUrl),
      idolName: record.idolName,
      groupName: record.groupName,
      colors: record.colors,
      weiboUid: record.weiboUid,
      weiboUsername: record.weiboUsername,
      weiboVerification: record.weiboVerification
    })
  },

  openIdolDialogFromProfile(profile, record) {
    const prefill = this.getIdolAddPrefill(profile.username, profile.verification)
    this.openIdolDialog({
      mode: record ? 'modify' : 'create',
      recordId: record ? record.id : '',
      avatarUrl: profile.avatarUrl || '',
      idolName: record ? record.idolName : prefill.idolname,
      groupName: record ? record.groupName : prefill.groupname,
      colors: record ? record.colors : [],
      weiboUid: profile.uid || '',
      weiboUsername: profile.username || '',
      weiboVerification: profile.verification || ''
    })
  },

  openIdolDialog(options) {
    const colorOptions = createColorOptions(options.colors || [])
    this.setData({
      showIdolAddDialog: true,
      idolDialogTitle: options.mode === 'modify' ? 'Modify Idol' : 'Add Idol',
      idolAddMode: options.mode || 'create',
      idolAddRecordId: options.recordId || '',
      idolAddWeiboUid: options.weiboUid || '',
      idolAddWeiboUsername: options.weiboUsername || '',
      idolAddWeiboVerification: options.weiboVerification || '',
      idolAddAvatarUrl: options.avatarUrl || '',
      idolAddName: options.idolName || '',
      idolAddGroupName: options.groupName || '',
      idolAddColorOptions: colorOptions,
      idolAddCustomPanelOpen: false,
      idolAddCustomColor: {
        r: 37,
        g: 99,
        b: 235
      },
      idolAddNextCustomColorId: colorOptions.filter((option) => /^custom-/.test(option.id)).length + 1,
      idolAddSaving: false
    })
  },

  findIdolRecord(recordId) {
    const id = String(recordId || '')
    if (!id) return null
    return (this.data.idolRecords || []).find((record) => String(record.id) === id) || null
  },

  getIdolAddPrefill(username, verification) {
    const name = String(username || '').trim()
    const match = name.match(/^([^-_]+)[-_](.+)$/)
    if (!match || !match[1].trim() || !match[2].trim()) {
      return {
        idolname: '',
        groupname: ''
      }
    }

    const a = match[1].trim()
    const b = match[2].trim()
    const verificationText = String(verification || '').trim()
    if (verificationText && verificationText.indexOf('偶像') >= 0) {
      const c = verificationText.split('偶像')[0]
      if (c.indexOf(a) >= 0) {
        return {
          idolname: b,
          groupname: a
        }
      }
    }

    return {
      idolname: a,
      groupname: b
    }
  },

  closeIdolAddDialog() {
    if (this.data.idolAddSaving) return
    this.setData({
      showIdolAddDialog: false,
      idolAddCustomPanelOpen: false,
      idolDialogTitle: 'Add Idol',
      idolAddMode: 'create',
      idolAddRecordId: '',
      idolAddWeiboUid: '',
      idolAddWeiboUsername: '',
      idolAddWeiboVerification: '',
      idolAddSaving: false
    })
  },

  closeIdolColorPicker() {
    this.setData({
      idolAddCustomPanelOpen: false
    })
  },

  noop() {},

  onIdolNameInput(event) {
    this.setData({
      idolAddName: event.detail.value || ''
    })
  },

  onGroupNameInput(event) {
    this.setData({
      idolAddGroupName: event.detail.value || ''
    })
  },

  chooseIdolAvatar() {
    wx.chooseImage({
      count: 1,
      sizeType: ['compressed', 'original'],
      sourceType: ['album'],
      success: (res) => {
        const path = res && res.tempFilePaths && res.tempFilePaths[0]
        if (!path) return
        this.setData({
          idolAddAvatarUrl: path
        })
      },
      fail: (err) => {
        const errMsg = err && err.errMsg ? err.errMsg : ''
        if (!/cancel/i.test(errMsg)) {
          wx.showToast({ title: '选择图片失败', icon: 'none' })
        }
      }
    })
  },

  toggleIdolColor(event) {
    const index = Number(event.currentTarget.dataset.index)
    const options = this.data.idolAddColorOptions.slice()
    const option = options[index]
    if (!option) return
    if (option.isOther) {
      this.setData({ idolAddCustomPanelOpen: true })
      return
    }

    options[index] = Object.assign({}, option, {
      selected: !option.selected
    })
    this.setData({
      idolAddColorOptions: options
    })
  },

  onCustomColorSliderChange(event) {
    this.updateCustomColor(event.currentTarget.dataset.channel, event.detail.value)
  },

  onCustomColorInput(event) {
    this.updateCustomColor(event.currentTarget.dataset.channel, event.detail.value)
  },

  updateCustomColor(channel, value) {
    if (!channel) return
    const color = Object.assign({}, this.data.idolAddCustomColor)
    color[channel] = clampRgb(value)
    this.setData({
      idolAddCustomColor: color
    })
  },

  addCustomColor() {
    const options = this.data.idolAddColorOptions.slice()
    const otherIndex = options.findIndex((option) => option.isOther)
    const customColorCount = options.filter((option) => /^custom-/.test(option.id)).length
    if (otherIndex < 0 || customColorCount >= IDOL_MAX_CUSTOM_COLORS) return

    const nextId = this.data.idolAddNextCustomColorId
    const value = rgbToHex(this.data.idolAddCustomColor)
    options[otherIndex] = {
      id: `custom-${nextId}`,
      label: value,
      value,
      selected: true,
      isOther: false
    }
    if (customColorCount + 1 < IDOL_MAX_CUSTOM_COLORS) {
      options.push(createOtherColorOption(nextId))
    }
    this.setData({
      idolAddColorOptions: options,
      idolAddCustomPanelOpen: false,
      idolAddNextCustomColorId: nextId + 1
    })
  },

  getSelectedIdolColors() {
    return normalizeColorList((this.data.idolAddColorOptions || [])
      .filter((option) => option && option.selected && !option.isOther)
      .map((option) => option.value))
  },

  submitIdolDialog() {
    if (this.data.idolAddSaving) return

    const idolName = String(this.data.idolAddName || '').trim()
    const groupName = String(this.data.idolAddGroupName || '').trim()
    if (!idolName || !groupName) {
      wx.showToast({ title: '请填写名称和团体', icon: 'none' })
      return
    }

    const payload = {
      idol_name: idolName,
      group_name: groupName,
      colors: this.getSelectedIdolColors(),
      weibo_uid: this.data.idolAddWeiboUid || '',
      weibo_username: this.data.idolAddWeiboUsername || '',
      weibo_verification: this.data.idolAddWeiboVerification || ''
    }
    const avatarUrl = this.data.idolAddAvatarUrl || ''

    this.setData({ idolAddSaving: true })
    const save = this.prepareIdolSavePayload(payload, avatarUrl)
      .then((nextPayload) => this.requestIdolRecordSave(nextPayload))

    save.then(() => {
      wx.showToast({ title: this.data.idolAddMode === 'modify' ? '已更新' : '已保存', icon: 'success' })
      this.setData({
        weiboUrl: '',
        errorText: '',
        emptyText: '',
        statusText: '',
        statusKind: 'idle',
        profile: null,
        profileActionLabel: 'Add',
        profileMatchedRecordId: '',
        profileStoredRecords: [],
        fields: [],
        avatarStatus: '',
        showIdolAddDialog: false,
        idolAddCustomPanelOpen: false,
        idolAddSaving: false
      })
      this.loadIdolRecords()
    }).catch((err) => {
      console.warn('[idols] save failed', err)
      this.setData({ idolAddSaving: false })
      wx.showToast({ title: err && err.message ? err.message : '保存失败', icon: 'none' })
    })
  },

  prepareIdolSavePayload(payload, avatarUrl) {
    const nextPayload = Object.assign({}, payload)
    if (!avatarUrl) return Promise.resolve(nextPayload)
    if (isDataAvatarUrl(avatarUrl)) {
      nextPayload.avatar_data_url = avatarUrl
      nextPayload.avatar_content_type = getDataAvatarContentType(avatarUrl)
      nextPayload.avatar_kind = 'data_url'
      return Promise.resolve(nextPayload)
    }
    if (!isLocalAvatarPath(avatarUrl)) {
      if (isTrustedPublicAvatarUrl(avatarUrl)) {
        nextPayload.avatar_public_url = avatarUrl
        nextPayload.avatar_kind = 'public_url'
        return Promise.resolve(nextPayload)
      }
      return this.readRemoteAvatarDataUrl(avatarUrl).then((avatar) => {
        nextPayload.avatar_data_url = avatar.dataUrl
        nextPayload.avatar_content_type = avatar.contentType
        return nextPayload
      })
    }

    return this.readLocalAvatarDataUrl(avatarUrl).then((avatar) => {
      nextPayload.avatar_data_url = avatar.dataUrl
      nextPayload.avatar_content_type = avatar.contentType
      return nextPayload
    })
  },

  readRemoteAvatarDataUrl(url) {
    return new Promise((resolve, reject) => {
      wx.downloadFile({
        url,
        header: { Accept: 'image/*' },
        success: (res) => {
          if (res.statusCode >= 200 && res.statusCode < 300 && res.tempFilePath) {
            this.readLocalAvatarDataUrl(res.tempFilePath, inferImageContentType(url)).then(resolve).catch(reject)
            return
          }
          const error = new Error(`avatar download HTTP ${res.statusCode || 'unknown'}`)
          error.statusCode = res.statusCode
          reject(error)
        },
        fail: (err) => {
          reject(new Error(err && err.errMsg ? err.errMsg : '头像下载失败'))
        }
      })
    })
  },

  readLocalAvatarDataUrl(filePath, contentTypeHint) {
    return new Promise((resolve, reject) => {
      if (!wx.getFileSystemManager) {
        reject(new Error('无法读取本地头像文件'))
        return
      }
      wx.getFileSystemManager().readFile({
        filePath,
        encoding: 'base64',
        success: (res) => {
          const base64 = res && res.data ? String(res.data) : ''
          if (!base64) {
            reject(new Error('本地头像为空'))
            return
          }
          const contentType = contentTypeHint || inferImageContentType(filePath)
          resolve({
            contentType,
            dataUrl: `data:${contentType};base64,${base64}`
          })
        },
        fail: (err) => {
          reject(new Error(err && err.errMsg ? err.errMsg : '读取本地头像失败'))
        }
      })
    })
  },

  requestIdolRecordSave(payload) {
    const isModify = this.data.idolAddMode === 'modify' && this.data.idolAddRecordId
    const now = new Date().toISOString()
    const records = getLocalIdolRecords()
    const recordId = isModify ? String(this.data.idolAddRecordId) : createLocalIdolRecordId()
    const existingIndex = records.findIndex((record) => String(record && record.id) === recordId)
    const existing = existingIndex >= 0 ? records[existingIndex] : {}
    const nextRecord = Object.assign({}, existing, {
      id: recordId,
      idolName: payload.idol_name || '',
      groupName: payload.group_name || '',
      colors: normalizeColorList(payload.colors),
      weiboUid: payload.weibo_uid || '',
      weiboUsername: payload.weibo_username || '',
      weiboVerification: payload.weibo_verification || '',
      createdAt: existing.createdAt || now,
      updatedAt: now
    })

    if (payload.avatar_public_url) {
      nextRecord.avatarKind = 'public_url'
      nextRecord.avatarUrl = payload.avatar_public_url
      nextRecord.avatarPublicUrl = payload.avatar_public_url
      delete nextRecord.avatarDataUrl
      delete nextRecord.avatarContentType
    } else if (payload.avatar_data_url) {
      nextRecord.avatarKind = 'data_url'
      nextRecord.avatarUrl = payload.avatar_data_url
      nextRecord.avatarDataUrl = payload.avatar_data_url
      nextRecord.avatarContentType = payload.avatar_content_type || getDataAvatarContentType(payload.avatar_data_url)
      delete nextRecord.avatarPublicUrl
    }

    if (existingIndex >= 0) {
      records[existingIndex] = nextRecord
    } else {
      records.unshift(nextRecord)
    }
    saveLocalIdolRecords(records)
    return Promise.resolve({ data: { ok: true, record: nextRecord } })
  },

  confirmDeleteIdolRecord(event) {
    const recordId = event && event.currentTarget && event.currentTarget.dataset
      ? event.currentTarget.dataset.recordId
      : ''
    const record = this.findIdolRecord(recordId)
    if (!record) return

    wx.showModal({
      title: '删除偶像记录',
      content: `确定删除 ${record.idolName || record.weiboUsername || '这条记录'} 吗？`,
      confirmText: '删除',
      confirmColor: '#ef4444',
      cancelText: '取消',
      success: (res) => {
        if (!res.confirm) return
        this.deleteIdolRecord(record.id)
      }
    })
  },

  deleteIdolRecord(recordId) {
    Promise.resolve().then(() => {
      deleteLocalIdolRecord(recordId)
      wx.showToast({ title: '已删除', icon: 'success' })
      this.loadIdolRecords()
    }).catch((err) => {
      console.warn('[idols] delete failed', err)
      wx.showToast({ title: err && err.message ? err.message : '删除失败', icon: 'none' })
    })
  }
})
