const LOCAL_USER_DATA_STORAGE_KEY = 'chekinana_local_user_data'
const LOCAL_USER_DATA_CLOUD_HASH_KEY = 'chekinana_local_user_data_cloud_hash'
const LOCAL_USER_DATA_LAST_SYNCED_HASH_KEY = 'chekinana_local_user_data_last_synced_hash'
const LOCAL_USER_DATA_LAST_SYNCED_AT_KEY = 'chekinana_local_user_data_last_synced_at'
const LOCAL_USER_DATA_VERSION = 1

function nowIsoString() {
  return new Date().toISOString()
}

function createEmptyLocalUserDataBundle() {
  return {
    version: LOCAL_USER_DATA_VERSION,
    updatedAt: nowIsoString(),
    domains: {
      idols: {
        records: []
      },
      calendar: {
        records: []
      }
    }
  }
}

function normalizeBundle(value) {
  const source = value && typeof value === 'object' ? value : {}
  const domains = source.domains && typeof source.domains === 'object' ? source.domains : {}
  const idols = domains.idols && typeof domains.idols === 'object' ? domains.idols : {}
  const calendar = domains.calendar && typeof domains.calendar === 'object' ? domains.calendar : {}

  return {
    version: Number(source.version) || LOCAL_USER_DATA_VERSION,
    updatedAt: source.updatedAt || nowIsoString(),
    domains: Object.assign({}, domains, {
      idols: Object.assign({}, idols, {
        records: Array.isArray(idols.records) ? idols.records : []
      }),
      calendar: Object.assign({}, calendar, {
        records: Array.isArray(calendar.records) ? calendar.records : []
      })
    })
  }
}

function getLocalUserDataBundle() {
  try {
    const stored = wx.getStorageSync(LOCAL_USER_DATA_STORAGE_KEY)
    if (!stored) return createEmptyLocalUserDataBundle()
    if (typeof stored === 'string') {
      return normalizeBundle(JSON.parse(stored))
    }
    return normalizeBundle(stored)
  } catch (err) {
    console.warn('[local-user-data] read failed', err)
    return createEmptyLocalUserDataBundle()
  }
}

function saveLocalUserDataBundle(bundle) {
  const nextBundle = normalizeBundle(bundle)
  nextBundle.version = LOCAL_USER_DATA_VERSION
  nextBundle.updatedAt = nowIsoString()
  wx.setStorageSync(LOCAL_USER_DATA_STORAGE_KEY, nextBundle)
  return nextBundle
}

function getLocalIdolRecords() {
  const bundle = getLocalUserDataBundle()
  return bundle.domains.idols.records.slice()
}

function saveLocalIdolRecords(records) {
  const bundle = getLocalUserDataBundle()
  bundle.domains.idols.records = Array.isArray(records) ? records.slice() : []
  return saveLocalUserDataBundle(bundle).domains.idols.records
}

function deleteLocalIdolRecord(recordId) {
  const id = String(recordId || '')
  if (!id) return getLocalIdolRecords()
  const records = getLocalIdolRecords().filter((record) => String(record && record.id) !== id)
  return saveLocalIdolRecords(records)
}

function getLocalCalendarRecords() {
  const bundle = getLocalUserDataBundle()
  return bundle.domains.calendar.records.slice()
}

function saveLocalCalendarRecords(records) {
  const bundle = getLocalUserDataBundle()
  bundle.domains.calendar.records = Array.isArray(records) ? records.slice() : []
  return saveLocalUserDataBundle(bundle).domains.calendar.records
}

function deleteLocalCalendarRecord(recordId) {
  const id = String(recordId || '')
  if (!id) return getLocalCalendarRecords()
  const records = getLocalCalendarRecords().filter((record) => String(record && record.id) !== id)
  return saveLocalCalendarRecords(records)
}

function getLocalUserDataSyncMeta() {
  return {
    cloudHash: wx.getStorageSync(LOCAL_USER_DATA_CLOUD_HASH_KEY) || '',
    lastSyncedHash: wx.getStorageSync(LOCAL_USER_DATA_LAST_SYNCED_HASH_KEY) || '',
    lastSyncedAt: wx.getStorageSync(LOCAL_USER_DATA_LAST_SYNCED_AT_KEY) || ''
  }
}

function saveLocalUserDataSyncMeta(meta) {
  const nextMeta = meta && typeof meta === 'object' ? meta : {}
  if (nextMeta.cloudHash !== undefined) {
    wx.setStorageSync(LOCAL_USER_DATA_CLOUD_HASH_KEY, nextMeta.cloudHash || '')
  }
  if (nextMeta.lastSyncedHash !== undefined) {
    wx.setStorageSync(LOCAL_USER_DATA_LAST_SYNCED_HASH_KEY, nextMeta.lastSyncedHash || '')
  }
  if (nextMeta.lastSyncedAt !== undefined) {
    wx.setStorageSync(LOCAL_USER_DATA_LAST_SYNCED_AT_KEY, nextMeta.lastSyncedAt || '')
  }
  return getLocalUserDataSyncMeta()
}

module.exports = {
  LOCAL_USER_DATA_STORAGE_KEY,
  LOCAL_USER_DATA_CLOUD_HASH_KEY,
  LOCAL_USER_DATA_LAST_SYNCED_HASH_KEY,
  LOCAL_USER_DATA_LAST_SYNCED_AT_KEY,
  LOCAL_USER_DATA_VERSION,
  createEmptyLocalUserDataBundle,
  getLocalUserDataBundle,
  saveLocalUserDataBundle,
  getLocalIdolRecords,
  saveLocalIdolRecords,
  deleteLocalIdolRecord,
  getLocalCalendarRecords,
  saveLocalCalendarRecords,
  deleteLocalCalendarRecord,
  getLocalUserDataSyncMeta,
  saveLocalUserDataSyncMeta
}
