const { API_BASE_URL, AUTH_STORAGE_KEY } = require("../../utils/config");
const POLL_INTERVAL_MS = 2000;
const MAX_POLL_COUNT = 90;
const MAX_ROTATE_CANVAS_SIDE = 1600;

Page({
  data: {
    inputPath: "",
    extractedImages: [],
    processing: false,
    wbEnabled: true,
    statusText: "请选择一张包含拍立得的照片",
    statusKind: "idle"
  },

  pollTimer: null,
  pollCount: 0,

  onUnload() {
    this.clearPollTimer();
  },

  onShow() {
    if (!this.getAuthToken()) {
      wx.redirectTo({ url: "/pages/auth/auth" });
    }
  },

  getAuthToken() {
    return wx.getStorageSync(AUTH_STORAGE_KEY) || "";
  },

  getAuthHeader() {
    const token = this.getAuthToken();
    return token ? { "X-Cheki-Token": token } : {};
  },

  chooseImage() {
    if (this.data.processing) return;

    wx.chooseMedia({
      count: 1,
      mediaType: ["image"],
      sourceType: ["album", "camera"],
      sizeType: ["compressed"],
      success: (res) => {
        const file = res.tempFiles && res.tempFiles[0];
        if (!file || !file.tempFilePath) {
          wx.showToast({ title: "未选择图片", icon: "none" });
          return;
        }

        this.clearPollTimer();
        this.setData({
          inputPath: file.tempFilePath,
          extractedImages: [],
          statusText: "图片已选择，点击开始提取",
          statusKind: "ready"
        });
      },
      fail: () => {
        wx.showToast({ title: "选择图片失败", icon: "none" });
      }
    });
  },

  onWhiteBalanceChange(event) {
    this.setData({
      wbEnabled: !!event.detail.value
    });
  },

  rotateInputImage() {
    if (!this.data.inputPath || this.data.processing) return;

    this.setData({
      processing: true
    });

    wx.getImageInfo({
      src: this.data.inputPath,
      success: (info) => {
        this.drawRotatedImage(info.path, info.width, info.height);
      },
      fail: (err) => {
        console.error("getImageInfo for rotate failed", err);
        this.finishRotateWithError("读取图片失败");
      }
    });
  },

  drawRotatedImage(path, sourceWidth, sourceHeight) {
    this.createSelectorQuery()
      .select("#rotateCanvas")
      .fields({ node: true })
      .exec((res) => {
        const canvas = res && res[0] && res[0].node;
        if (!canvas) {
          this.finishRotateWithError("画布初始化失败");
          return;
        }

        const scale = Math.min(1, MAX_ROTATE_CANVAS_SIDE / Math.max(sourceWidth, sourceHeight));
        const outputWidth = Math.max(1, Math.round(sourceHeight * scale));
        const outputHeight = Math.max(1, Math.round(sourceWidth * scale));

        canvas.width = outputWidth;
        canvas.height = outputHeight;

        const ctx = canvas.getContext("2d");
        const image = canvas.createImage();

        image.onload = () => {
          ctx.clearRect(0, 0, outputWidth, outputHeight);
          ctx.save();
          ctx.translate(0, outputHeight);
          ctx.rotate(-Math.PI / 2);
          ctx.drawImage(image, 0, 0, outputHeight, outputWidth);
          ctx.restore();

          setTimeout(() => {
            wx.canvasToTempFilePath({
              canvas,
              x: 0,
              y: 0,
              width: outputWidth,
              height: outputHeight,
              destWidth: outputWidth,
              destHeight: outputHeight,
              fileType: "jpg",
              quality: 0.92,
              success: (result) => {
                this.setData({
                  inputPath: result.tempFilePath,
                  extractedImages: [],
                  processing: false,
                  statusText: "图片已选择，点击开始提取",
                  statusKind: "ready"
                });
              },
              fail: (err) => {
                console.error("rotate canvasToTempFilePath failed", err);
                this.finishRotateWithError("旋转图片失败");
              }
            });
          }, 80);
        };

        image.onerror = (err) => {
          console.error("rotate image load failed", err);
          this.finishRotateWithError("图片绘制失败");
        };

        image.src = path;
      });
  },

  finishRotateWithError(message) {
    this.setData({
      processing: false,
      statusText: message || "旋转失败",
      statusKind: "error"
    });
    wx.showToast({ title: message || "旋转失败", icon: "none" });
  },

  startExtract() {
    if (!this.data.inputPath || this.data.processing) return;

    const token = this.getAuthToken();
    if (!token) {
      wx.redirectTo({ url: "/pages/auth/auth" });
      return;
    }

    if (!API_BASE_URL) {
      wx.showModal({
        title: "需要配置接口",
        content: "请先在 pages/index/index.js 中配置 API_BASE_URL。",
        showCancel: false
      });
      return;
    }

    this.clearPollTimer();
    this.pollCount = 0;
    this.setData({
      processing: true,
      extractedImages: [],
      statusText: "正在上传图片...",
      statusKind: "processing"
    });

    wx.uploadFile({
      url: `${API_BASE_URL}/api/process`,
      filePath: this.data.inputPath,
      name: "image",
      header: this.getAuthHeader(),
      formData: {
        token,
        wb: this.data.wbEnabled ? "1" : "0"
      },
      success: (res) => {
        const payload = this.parseResponse(res.data);
        if (!payload) {
          this.finishWithError("服务器未启用，请联系作者");
          return;
        }
        this.handleProcessPayload(payload);
      },
      fail: (err) => {
        console.error("uploadFile failed", err);
        this.finishWithError(this.getUploadErrorMessage(err));
      }
    });
  },

  getUploadErrorMessage(err) {
    const errMsg = err && err.errMsg ? err.errMsg : "";
    if (errMsg.includes("url not in domain list") || errMsg.includes("domain list")) {
      return `上传域名未配置到微信合法域名：${errMsg}`;
    }
    if (errMsg.includes("timeout")) {
      return "上传超时，请稍后重试";
    }
    if (errMsg.includes("fail")) {
      return `上传失败：${errMsg}`;
    }
    return "上传失败，请检查网络或域名配置";
  },

  parseResponse(raw) {
    if (!raw) return null;
    if (typeof raw === "object") return raw;
    try {
      return JSON.parse(raw);
    } catch (err) {
      console.error("parse response failed", err, raw);
      return null;
    }
  },

  handleProcessPayload(payload) {
    if (payload.error || payload.message && payload.status === "error") {
      this.finishWithError(payload.error || payload.message);
      return;
    }

    const images = this.normalizeImages(payload);
    if (images.length > 0) {
      this.finishWithImages(images);
      return;
    }

    const taskId = payload.task_id || payload.taskId || payload.id;
    if (taskId) {
      this.setData({
        statusText: "图片处理中...",
        statusKind: "processing"
      });
      this.pollTask(taskId);
      return;
    }

    this.finishWithError("没有收到处理任务或结果图片");
  },

  pollTask(taskId) {
    this.clearPollTimer();
    this.pollTimer = setTimeout(() => {
      this.pollCount += 1;
      if (this.pollCount > MAX_POLL_COUNT) {
        this.finishWithError("处理超时，请稍后重试");
        return;
      }

      wx.request({
        url: `${API_BASE_URL}/api/status/${taskId}`,
        method: "GET",
        header: this.getAuthHeader(),
        success: (res) => {
          const payload = res.data;
          if (!payload || typeof payload !== "object") {
            this.finishWithError("服务器未启用，请联系作者");
            return;
          }
          const status = payload.status || payload.state;
          const images = this.normalizeImages(payload, taskId);

          if (images.length > 0 || status === "done" || status === "finished" || status === "success") {
            if (images.length > 0) {
              this.finishWithImages(images);
            } else {
              this.finishWithError("处理结束，但未提取到拍立得");
            }
            return;
          }

          if (status === "failed" || status === "error") {
            this.finishWithError(payload.error || payload.message || "处理失败");
            return;
          }

          this.setData({
            statusText: `图片处理中... ${this.pollCount * 2}s`,
            statusKind: "processing"
          });
          this.pollTask(taskId);
        },
        fail: (err) => {
          console.error("status request failed", err);
          this.finishWithError("查询处理状态失败");
        }
      });
    }, POLL_INTERVAL_MS);
  },

  normalizeImages(payload, taskId) {
    const list = payload.images || payload.results || payload.outputs || payload.files || [];
    const typedPolaroids = list.filter((item) => item && typeof item === "object" && item.type === "polaroid");
    const sourceList = typedPolaroids.length > 0 ? typedPolaroids : list;

    return sourceList
      .map((item, index) => {
        if (!item) return null;
        const hasResultId = typeof item === "object"
          && Object.prototype.hasOwnProperty.call(item, "id")
          && taskId;
        const rawUrl = typeof item === "string"
          ? item
          : item.url || item.download_url || item.downloadUrl || item.path || item.tempFilePath
            || (hasResultId ? `/api/result/${taskId}/${item.id}` : "");
        const url = this.resolveUrl(rawUrl);
        if (!url) return null;
        return {
          id: typeof item === "object" ? item.id || item.name || `p${index + 1}` : `p${index + 1}`,
          url,
          title: typeof item === "object" && item.label ? item.label : `拍立得 ${index + 1}`
        };
      })
      .filter(Boolean);
  },

  resolveUrl(url) {
    if (!url) return "";
    if (url.startsWith("http://") || url.startsWith("https://") || url.startsWith("wxfile://")) {
      return this.withAuthQuery(url);
    }
    if (url.startsWith("/")) {
      return this.withAuthQuery(`${API_BASE_URL}${url}`);
    }
    return this.withAuthQuery(`${API_BASE_URL}/${url}`);
  },

  withAuthQuery(url) {
    const token = this.getAuthToken();
    if (!token || url.startsWith("wxfile://")) return url;
    const separator = url.includes("?") ? "&" : "?";
    return `${url}${separator}token=${encodeURIComponent(token)}`;
  },

  finishWithImages(images) {
    this.clearPollTimer();
    this.setData({
      extractedImages: images,
      processing: false,
      statusText: `处理结束，提取了 ${images.length} 张拍立得`,
      statusKind: "done"
    });
  },

  finishWithError(message) {
    this.clearPollTimer();
    this.setData({
      processing: false,
      statusText: message || "处理失败",
      statusKind: "error"
    });
    wx.showToast({ title: message || "处理失败", icon: "none" });
  },

  saveResult(event) {
    const index = event.currentTarget.dataset.index;
    const image = this.data.extractedImages[index];
    if (!image || !image.url) return;

    wx.showLoading({ title: "保存中..." });

    if (image.url.startsWith("wxfile://")) {
      this.saveToAlbum(image.url);
      return;
    }

    wx.downloadFile({
      url: image.url,
      header: this.getAuthHeader(),
      success: (res) => {
        if (res.statusCode >= 200 && res.statusCode < 300 && res.tempFilePath) {
          this.saveToAlbum(res.tempFilePath);
          return;
        }
        wx.hideLoading();
        wx.showToast({ title: "下载失败", icon: "none" });
      },
      fail: (err) => {
        console.error("downloadFile failed", err);
        wx.hideLoading();
        wx.showToast({ title: "下载失败", icon: "none" });
      }
    });
  },

  saveToAlbum(filePath) {
    wx.saveImageToPhotosAlbum({
      filePath,
      success: () => {
        wx.hideLoading();
        wx.showToast({ title: "已保存", icon: "success" });
      },
      fail: (err) => {
        wx.hideLoading();
        if (err.errMsg && err.errMsg.includes("auth deny")) {
          wx.showModal({
            title: "需要相册权限",
            content: "请在设置中允许保存到相册。",
            confirmText: "去设置",
            success: (res) => {
              if (res.confirm) wx.openSetting();
            }
          });
          return;
        }
        wx.showToast({ title: "保存失败", icon: "none" });
      }
    });
  },

  clearPollTimer() {
    if (this.pollTimer) {
      clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }
  }
});
