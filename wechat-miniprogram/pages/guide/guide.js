Page({
  data: {
    images: [],
    selectedTag: 0,
    tags: ['标签一', '标签二', '标签三', '标签四']
  },

  selectTag(event) {
    this.setData({
      selectedTag: event.currentTarget.dataset.index
    })
  },

  chooseImage() {
    wx.chooseMedia({
      count: 9,
      mediaType: ['image'],
      sourceType: ['album'],
      success: (res) => {
        this.setData({
          images: res.tempFiles.map((file) => file.tempFilePath)
        })
      }
    })
  }
})
