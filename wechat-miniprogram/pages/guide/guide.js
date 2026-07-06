Page({
  data: {
    prompt: '',
    images: []
  },

  onPromptInput(event) {
    this.setData({
      prompt: event.detail.value
    })
  },

  chooseImage() {
    wx.chooseMedia({
      count: 9,
      mediaType: ['image'],
      sourceType: ['album', 'camera'],
      success: (res) => {
        this.setData({
          images: (res.tempFiles || []).map((file) => file.tempFilePath)
        })
      }
    })
  },

  submitPrompt() {
    // Placeholder only. Existing backend/API contracts remain unchanged.
  }
})
