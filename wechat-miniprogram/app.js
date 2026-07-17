const { preloadLianliankanTileAssets } = require('./utils/lianliankan-assets')

App({
  onLaunch() {
    preloadLianliankanTileAssets().catch((err) => {
      console.warn('[lianliankan] startup tile asset preload failed', err)
    })
  },

  globalData: {}
})
