const TILE_TYPES = 14
const ASSET_MANIFEST_URL = 'https://chekinana.top/assets/lianliankan/v1/manifest.json'
const ASSET_IMAGE_BASE_URL = 'https://chekinana.top/assets/lianliankan/v1/images/'
const ASSET_CACHE_KEY = 'lianliankan_asset_cache_v1'

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

let preloadPromise = null

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

function readTextFile(filePath, apiName, url) {
  if (typeof wx.getFileSystemManager !== 'function') {
    return Promise.reject(createAssetError(apiName, url, 'file system manager unavailable'))
  }
  return new Promise((resolve, reject) => {
    wx.getFileSystemManager().readFile({
      filePath,
      encoding: 'utf8',
      success: (res) => resolve(res.data || ''),
      fail: (err) => {
        reject(createAssetError(apiName, url, getErrorMessage(err, 'readFile failed')))
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

function requestManifest() {
  return downloadFile(ASSET_MANIFEST_URL, 'manifest')
    .then((tempFilePath) => readTextFile(tempFilePath, 'manifest', ASSET_MANIFEST_URL))
    .then((content) => JSON.parse(content))
}

function normalizeAssetUrl(rawUrl, file) {
  if (rawUrl && /^https?:\/\//.test(rawUrl)) return rawUrl
  if (rawUrl && rawUrl.startsWith('/')) return `https://chekinana.top${rawUrl}`
  if (rawUrl && rawUrl.includes('/')) return `https://chekinana.top/${rawUrl.replace(/^\/+/, '')}`
  return `${ASSET_IMAGE_BASE_URL}${file}`
}

function normalizeManifest(rawManifest) {
  let manifest
  try {
    manifest = typeof rawManifest === 'string' ? JSON.parse(rawManifest) : rawManifest
  } catch (e) {
    throw createAssetError('manifest', ASSET_MANIFEST_URL, getErrorMessage(e, 'invalid json'))
  }
  if (!manifest || typeof manifest !== 'object') {
    throw createAssetError('manifest', ASSET_MANIFEST_URL, 'invalid asset manifest')
  }

  const version = String(manifest.version || manifest.assetVersion || '')
  if (!version) throw createAssetError('manifest', ASSET_MANIFEST_URL, 'manifest missing version')

  const rawImages = Array.isArray(manifest.images)
    ? manifest.images
    : Array.isArray(manifest.assets)
      ? manifest.assets
      : []
  if (!rawImages.length) throw createAssetError('manifest', ASSET_MANIFEST_URL, 'manifest missing images')

  const imagesByFile = {}
  rawImages.forEach((item) => {
    const file = typeof item === 'string'
      ? item.split('/').pop()
      : String(item.file || item.name || item.filename || item.id || '').split('/').pop()
    if (!file) return
    const explicitUrl = typeof item === 'object' ? item.url || item.href || item.path || '' : item
    imagesByFile[file] = { file, url: normalizeAssetUrl(explicitUrl, file) }
  })

  TILE_IMAGE_FILES.slice(1).forEach((file) => {
    if (!imagesByFile[file] || !imagesByFile[file].url) {
      throw createAssetError('manifest', ASSET_MANIFEST_URL, `manifest missing image ${file}`)
    }
  })

  return { version, imagesByFile }
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

async function buildCachedTileImages(manifest) {
  const cached = wx.getStorageSync(ASSET_CACHE_KEY) || {}
  const cachedImages = cached && cached.version === manifest.version && cached.images
    ? cached.images
    : {}
  const nextImages = {}
  const tileImages = ['']

  for (let type = 1; type <= TILE_TYPES; type++) {
    const file = TILE_IMAGE_FILES[type]
    const cachedPath = cachedImages[file]
    if (await canAccessFile(cachedPath)) {
      nextImages[file] = cachedPath
      tileImages[type] = cachedPath
      continue
    }

    const imageUrl = manifest.imagesByFile[file].url
    const tempFilePath = await downloadFile(imageUrl, 'downloadFile')
    const savedFilePath = await saveFile(tempFilePath, imageUrl)
    if (!await canAccessFile(savedFilePath)) {
      throw createAssetError('saveFile', imageUrl, 'saved file is not accessible')
    }
    nextImages[file] = savedFilePath
    tileImages[type] = savedFilePath
  }

  await setStorage(ASSET_CACHE_KEY, {
    version: manifest.version,
    images: nextImages,
    manifestUrl: ASSET_MANIFEST_URL,
    audio: cached && cached.audio
  })
  return tileImages
}

function ensureLianliankanTileAssets() {
  return requestManifest()
    .then((rawManifest) => buildCachedTileImages(normalizeManifest(rawManifest)))
}

function preloadLianliankanTileAssets() {
  if (preloadPromise) return preloadPromise
  preloadPromise = ensureLianliankanTileAssets()
    .catch((err) => {
      preloadPromise = null
      throw err
    })
  return preloadPromise
}

module.exports = {
  ASSET_CACHE_KEY,
  ASSET_MANIFEST_URL,
  TILE_IMAGE_FILES,
  TILE_TYPES,
  canAccessFile,
  ensureLianliankanTileAssets,
  preloadLianliankanTileAssets
}
