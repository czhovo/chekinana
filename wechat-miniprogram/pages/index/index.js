const { AUTH_STORAGE_KEY, getApiBaseUrl } = require("../../utils/config");
const POLL_INTERVAL_MS = 1000;
const MAX_POLL_COUNT = 180;

Page({
  data: {
    inputPath: "",
    extractedImages: [],
    processing: false,
    wbEnabled: true,
    expectedPolaroidCount: "",
    showCountInput: false,
    statusText: "请选择一张包含拍立得的照片",
    statusKind: "idle"
  },

  pollTimer: null,
  pollCount: 0,
  verifyingCachedToken: false,
  pendingAuthRestoreState: null,
  downloadingImageUrls: {},

  onUnload() {
    this.clearPollTimer();
  },

  onShow() {
    const token = this.getAuthToken();
    if (!token) {
      wx.redirectTo({ url: "/pages/auth/auth" });
      return;
    }
    this.verifyCachedToken(token);
  },

  getAuthToken() {
    return wx.getStorageSync(AUTH_STORAGE_KEY) || "";
  },

  getApiBaseUrl() {
    return getApiBaseUrl();
  },

  getAuthHeader() {
    const token = this.getAuthToken();
    return token ? { "X-Cheki-Token": token } : {};
  },

  verifyCachedToken(token) {
    if (this.verifyingCachedToken) return;

    const apiBaseUrl = this.getApiBaseUrl();
    if (!apiBaseUrl) {
      this.clearAuthAndRedirect();
      return;
    }

    this.verifyingCachedToken = true;
    this.pendingAuthRestoreState = this.getPostAuthRestoreState();
    this.setData({
      processing: true,
      statusText: "正在验证 Token...",
      statusKind: "processing"
    });
    wx.request({
      url: `${apiBaseUrl}/api/auth/verify`,
      method: "POST",
      header: {
        "content-type": "application/json",
        "X-Cheki-Token": token
      },
      data: { token },
      success: (res) => {
        this.verifyingCachedToken = false;
        const ok = res.statusCode >= 200
          && res.statusCode < 300
          && res.data
          && (res.data.ok === true || res.data.valid === true || res.data.status === "ok");

        if (!ok) {
          this.clearAuthAndRedirect();
          return;
        }

        this.setData(this.pendingAuthRestoreState || this.getPostAuthRestoreState());
        this.pendingAuthRestoreState = null;
      },
      fail: () => {
        this.verifyingCachedToken = false;
        this.clearAuthAndRedirect();
      }
    });
  },

  getPostAuthRestoreState() {
    if (this.data.processing) {
      return {
        processing: true,
        statusText: this.data.statusText || "图片处理中...",
        statusKind: this.data.statusKind || "processing",
        showCountInput: false
      };
    }

    if (this.data.extractedImages.length > 0) {
      return {
        processing: false,
        statusText: this.data.statusKind === "done"
          ? this.data.statusText
          : `处理结束，提取了 ${this.data.extractedImages.length} 张拍立得`,
        statusKind: "done",
        showCountInput: false
      };
    }

    if (this.data.inputPath) {
      return {
        processing: false,
        statusText: "图片已选择，点击开始提取",
        statusKind: "ready",
        showCountInput: true
      };
    }

    return {
      processing: false,
      statusText: "请选择一张包含拍立得的照片",
      statusKind: "idle",
      showCountInput: false
    };
  },

  clearAuthAndRedirect() {
    wx.removeStorageSync(AUTH_STORAGE_KEY);
    this.clearPollTimer();
    this.downloadingImageUrls = {};
    this.setData({
      processing: false,
      inputPath: "",
      extractedImages: [],
      expectedPolaroidCount: "",
      showCountInput: false,
      statusText: "请先输入有效 Token",
      statusKind: "error"
    });
    wx.redirectTo({ url: "/pages/auth/auth" });
  },

  chooseImage() {
    if (this.data.processing) return;

    wx.chooseMedia({
      count: 1,
      mediaType: ["image"],
      sourceType: ["album", "camera"],
      sizeType: ["original"],
      success: (res) => {
        const file = res.tempFiles && res.tempFiles[0];
        if (!file || !file.tempFilePath) {
          wx.showToast({ title: "未选择图片", icon: "none" });
          return;
        }

        this.clearPollTimer();
        this.downloadingImageUrls = {};
        const nextState = {
          inputPath: file.tempFilePath,
          extractedImages: [],
          processing: false,
          expectedPolaroidCount: "",
          showCountInput: true,
          statusText: "图片已选择，点击开始提取",
          statusKind: "ready"
        };
        this.pendingAuthRestoreState = nextState;
        this.setData(nextState);
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

  onExpectedCountInput(event) {
    const value = String(event.detail.value || "").replace(/\D/g, "").slice(0, 3);
    this.setData({
      expectedPolaroidCount: value
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

        const outputWidth = Math.max(1, Math.round(sourceHeight));
        const outputHeight = Math.max(1, Math.round(sourceWidth));

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
              fileType: "png",
              success: (result) => {
                this.setData({
                  inputPath: result.tempFilePath,
                  extractedImages: [],
                  processing: false,
                  showCountInput: true,
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

    const apiBaseUrl = this.getApiBaseUrl();
    if (!apiBaseUrl) {
      wx.showModal({
        title: "需要配置接口",
        content: "请先在 pages/index/index.js 中配置 API_BASE_URL。",
        showCancel: false
      });
      return;
    }

    this.clearPollTimer();
    this.pollCount = 0;
    this.downloadingImageUrls = {};
    const formData = {
      token,
      wb: this.data.wbEnabled ? "1" : "0"
    };
    const expectedCount = this.getExpectedPolaroidCount();
    if (expectedCount) {
      formData.expected_polaroids = expectedCount;
      formData.polaroid_count = expectedCount;
    }
    this.setData({
      processing: true,
      extractedImages: [],
      showCountInput: false,
      statusText: "正在上传图片...",
      statusKind: "processing"
    });

    wx.uploadFile({
      url: `${apiBaseUrl}/api/process`,
      filePath: this.data.inputPath,
      name: "image",
      header: this.getAuthHeader(),
      formData,
      success: (res) => {
        const payload = this.parseResponse(res.data);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          this.finishWithError(this.getResponseErrorMessage(res, payload, "Upload failed"));
          return;
        }
        if (!payload) {
          this.finishWithError(this.getResponseErrorMessage(res, payload, "Unexpected upload response"));
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
      return "处理时间过长 请稍后重试";
    }
    if (errMsg.includes("fail")) {
      return `上传失败：${errMsg}`;
    }
    return "上传失败，请检查网络或域名配置";
  },

  getExpectedPolaroidCount() {
    const value = parseInt(this.data.expectedPolaroidCount, 10);
    return Number.isFinite(value) && value > 0 ? String(value) : "";
  },

  getResponseErrorMessage(res, payload, fallback) {
    const statusCode = res && res.statusCode ? res.statusCode : 0;
    if (statusCode === 404 && fallback === "Upload failed") {
      return "Upload failed(404) 可能是服务器已关闭 请联系作者";
    }
    if (statusCode === 502 && fallback === "Upload failed") {
      return "Upload failed(502) 后端服务暂时不可用 请联系作者";
    }
    if (payload && (payload.error || payload.message)) {
      return payload.error || payload.message;
    }
    const raw = res && typeof res.data === "string" ? res.data.trim() : "";
    const snippet = raw ? raw.replace(/\s+/g, " ").slice(0, 80) : "";
    if (statusCode) {
      return snippet ? `${fallback}(${statusCode}): ${snippet}` : `${fallback}(${statusCode})`;
    }
    return snippet ? `${fallback}: ${snippet}` : fallback;
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
        this.finishWithError("处理时间过长 请稍后重试");
        return;
      }

      wx.request({
        url: `${this.getApiBaseUrl()}/api/status/${taskId}`,
        method: "GET",
        header: this.getAuthHeader(),
        success: (res) => {
          const payload = res.data;
          if (res.statusCode < 200 || res.statusCode >= 300) {
            this.finishWithError(this.getResponseErrorMessage(res, payload, "Status failed"));
            return;
          }
          if (!payload || typeof payload !== "object") {
            this.finishWithError(this.getResponseErrorMessage(res, payload, "Unexpected status response"));
            return;
          }
          const status = payload.status || payload.state;
          const images = this.normalizeImages(payload, taskId);
          this.updatePartialImages(images);
          const expectedCount = Number(payload.expected_polaroids || payload.total_polaroids || 0);
          const warning = payload.warning || payload.detection_warning || "";
          const extractionComplete = payload.extraction_complete === true
            || payload.done_marker === true
            || payload.complete === true;

          if (extractionComplete) {
            if (images.length > 0) {
              this.finishWithImages(images, warning);
            } else if (warning) {
              this.finishWithNotice(warning);
            } else {
              this.finishWithError("处理结束，但未提取到拍立得");
            }
            return;
          }

          if (status === "done" || status === "finished" || status === "success") {
            if (images.length > 0) {
              this.finishWithImages(images, warning);
            } else if (warning) {
              this.finishWithNotice(warning);
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
            statusText: this.getProcessingStatusText(images.length, expectedCount, warning),
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
    const hasTypedResults = list.some((item) => item && typeof item === "object" && item.type);
    const typedPolaroids = list.filter((item) => item && typeof item === "object" && item.type === "polaroid");
    const sourceList = hasTypedResults ? typedPolaroids : list;

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
          id: typeof item === "object" && Object.prototype.hasOwnProperty.call(item, "id")
            ? item.id
            : typeof item === "object" && item.name
              ? item.name
              : `p${index + 1}`,
          url,
          title: typeof item === "object" && item.label ? item.label : `拍立得 ${index + 1}`
        };
      })
      .filter(Boolean);
  },

  updatePartialImages(images) {
    if (!images.length) return;

    const merged = this.mergeImages(this.data.extractedImages, images);
    if (merged.length !== this.data.extractedImages.length) {
      this.setData({ extractedImages: merged });
    }
    this.prefetchResultImages(merged);
  },

  mergeImages(currentImages, nextImages) {
    const imageMap = {};
    const merged = [];

    currentImages.concat(nextImages).forEach((image) => {
      if (!image || !image.url) return;
      const key = String(image.id || image.url);
      if (imageMap[key]) {
        Object.assign(imageMap[key], image);
        return;
      }
      const copy = Object.assign({}, image);
      imageMap[key] = copy;
      merged.push(copy);
    });

    return merged;
  },

  prefetchResultImages(images) {
    images.forEach((image) => {
      if (!image || !image.url || image.localPath || image.url.startsWith("wxfile://")) return;
      if (this.downloadingImageUrls[image.url]) return;

      this.downloadingImageUrls[image.url] = true;
      wx.downloadFile({
        url: image.url,
        header: this.getAuthHeader(),
        success: (res) => {
          if (res.statusCode >= 200 && res.statusCode < 300 && res.tempFilePath) {
            this.updateImageLocalPath(image, res.tempFilePath);
          }
        },
        complete: () => {
          delete this.downloadingImageUrls[image.url];
        }
      });
    });
  },

  updateImageLocalPath(targetImage, localPath) {
    const targetKey = String(targetImage.id || targetImage.url);
    const extractedImages = this.data.extractedImages.map((image) => {
      const key = String(image.id || image.url);
      if (key !== targetKey) return image;
      return Object.assign({}, image, { localPath });
    });
    this.setData({ extractedImages });
  },

  getProcessingStatusText(doneCount, expectedCount, warning) {
    if (warning && doneCount > 0 && expectedCount > 0) {
      return `${warning}，已提取 ${doneCount}/${expectedCount} 张`;
    }
    if (warning && doneCount > 0) {
      return `${warning}，已提取 ${doneCount} 张`;
    }
    if (warning) {
      return warning;
    }
    if (expectedCount > 0 && doneCount > 0) {
      return `已提取 ${doneCount}/${expectedCount} 张，继续处理`;
    }
    if (doneCount > 0) {
      return `已提取 ${doneCount} 张，继续处理`;
    }
    if (expectedCount > 0) {
      return `目标 ${expectedCount} 张，正在检测/提取`;
    }
    return "图片处理中...";
  },

  resolveUrl(url) {
    if (!url) return "";
    if (url.startsWith("http://") || url.startsWith("https://") || url.startsWith("wxfile://")) {
      return this.withAuthQuery(url);
    }
    if (url.startsWith("/")) {
      return this.withAuthQuery(`${this.getApiBaseUrl()}${url}`);
    }
    return this.withAuthQuery(`${this.getApiBaseUrl()}/${url}`);
  },

  withAuthQuery(url) {
    const token = this.getAuthToken();
    if (!token || url.startsWith("wxfile://")) return url;
    const separator = url.includes("?") ? "&" : "?";
    return `${url}${separator}token=${encodeURIComponent(token)}`;
  },

  finishWithImages(images, message) {
    this.clearPollTimer();
    const merged = this.mergeImages(this.data.extractedImages, images);
    this.setData({
      extractedImages: merged,
      processing: false,
      showCountInput: false,
      statusText: message || `处理结束，提取了 ${merged.length} 张拍立得`,
      statusKind: "done"
    });
    this.prefetchResultImages(merged);
  },

  finishWithNotice(message) {
    this.clearPollTimer();
    this.setData({
      processing: false,
      statusText: message || "处理结束",
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

    const localPath = image.localPath || (image.url.startsWith("wxfile://") ? image.url : "");
    if (localPath) {
      this.saveToAlbum(localPath, image);
      return;
    }

    this.downloadAndSaveImage(image);
  },

  downloadAndSaveImage(image) {
    wx.downloadFile({
      url: image.url,
      header: this.getAuthHeader(),
      success: (res) => {
        if (res.statusCode >= 200 && res.statusCode < 300 && res.tempFilePath) {
          this.updateImageLocalPath(image, res.tempFilePath);
          this.saveToAlbum(res.tempFilePath, image, false);
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

  saveToAlbum(filePath, fallbackImage, allowFallback = true) {
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
        if (allowFallback && fallbackImage && fallbackImage.url && fallbackImage.url !== filePath) {
          this.downloadAndSaveImage(fallbackImage);
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
