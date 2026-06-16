const { AUTH_STORAGE_KEY, getApiBaseUrl, isLocalPreviewToken } = require("../../utils/config");
const POLL_INTERVAL_MS = 1000;
const MAX_POLL_COUNT = 180;
const MAX_SELECTED_IMAGES = 9;
const CONTACT_MESSAGE_MAX_LENGTH = 1000;
const CONTACT_INFO_MAX_LENGTH = 200;

Page({
  data: {
    inputPath: "",
    selectedImages: [],
    currentImageIndex: 0,
    rotationDegrees: 0,
    previewRotationStyle: "",
    extractedImages: [],
    processing: false,
    wbEnabled: true,
    denoiseEnabled: true,
    expectedPolaroidCount: "",
    showCountInput: false,
    showContactDialog: false,
    contactMessage: "",
    contactInfo: "",
    contactSubmitting: false,
    statusText: "请选择一张包含拍立得的图片",
    statusKind: "idle"
  },

  pollTimer: null,
  pollCount: 0,
  verifyingCachedToken: false,
  pendingAuthRestoreState: null,
  downloadingImageUrls: {},
  activeBatchRunId: 0,
  activeTaskId: "",
  batchInterrupted: false,

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

    if (isLocalPreviewToken(token)) {
      this.setData(this.getPostAuthRestoreState());
      return;
    }

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
      statusText: "请选择一张包含拍立得的图片",
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
      selectedImages: [],
      currentImageIndex: 0,
      rotationDegrees: 0,
      previewRotationStyle: "",
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

    const remainingCount = MAX_SELECTED_IMAGES - this.data.selectedImages.length;
    if (remainingCount <= 0) {
      wx.showToast({ title: `最多添加 ${MAX_SELECTED_IMAGES} 张图片`, icon: "none" });
      return;
    }

    wx.chooseMedia({
      count: remainingCount,
      mediaType: ["image"],
      sourceType: ["album", "camera"],
      sizeType: ["original"],
      success: (res) => {
        const files = (res.tempFiles || []).filter((file) => file && file.tempFilePath);
        if (!files.length) {
          wx.showToast({ title: "未选择图片", icon: "none" });
          return;
        }

        this.clearPollTimer();
        this.downloadingImageUrls = {};
        const selectedImages = this.data.selectedImages.concat(
          files.slice(0, remainingCount).map((file) => this.createSelectedImage(file.tempFilePath))
        );
        const currentImageIndex = this.data.selectedImages.length ? this.data.currentImageIndex : 0;
        const nextState = Object.assign(this.getCurrentImageState(selectedImages, currentImageIndex), {
          selectedImages,
          currentImageIndex,
          extractedImages: [],
          processing: false,
          showCountInput: true,
          statusText: selectedImages.length > 1
            ? `已添加 ${selectedImages.length} 张图片，当前仍按单张流程处理`
            : "图片已选择，点击开始提取",
          statusKind: "ready"
        });
        this.pendingAuthRestoreState = nextState;
        this.setData(nextState);
      },
      fail: () => {
        wx.showToast({ title: "选择图片失败", icon: "none" });
      }
    });
  },

  onInputFrameTap() {
    if (this.data.processing) return;
    if (!this.data.inputPath) {
      this.chooseImage();
      return;
    }
    this.showDeleteCurrentImageAction();
  },

  showPreviousImage() {
    if (this.data.selectedImages.length <= 1) return;
    const currentImageIndex = (this.data.currentImageIndex - 1 + this.data.selectedImages.length)
      % this.data.selectedImages.length;
    this.setCurrentImageIndex(currentImageIndex);
  },

  showNextImage() {
    if (this.data.selectedImages.length <= 1) return;
    const currentImageIndex = (this.data.currentImageIndex + 1) % this.data.selectedImages.length;
    this.setCurrentImageIndex(currentImageIndex);
  },

  onSelectedImageTap(event) {
    const index = Number(event.currentTarget.dataset.index);
    if (!Number.isInteger(index)) return;
    this.setCurrentImageIndex(index);
  },

  setCurrentImageIndex(currentImageIndex) {
    const selectedImages = this.data.selectedImages;
    if (!selectedImages.length) return;
    const clampedIndex = Math.max(0, Math.min(currentImageIndex, selectedImages.length - 1));
    const nextState = Object.assign(this.getCurrentImageState(selectedImages, clampedIndex), {
      currentImageIndex: clampedIndex,
      showCountInput: !this.data.processing
    });
    if (!this.data.processing) {
      Object.assign(nextState, {
        extractedImages: [],
        statusText: selectedImages.length > 1
          ? `当前图片 ${clampedIndex + 1}/${selectedImages.length}，点击开始提取`
          : "图片已选择，点击开始提取",
        statusKind: "ready"
      });
    }
    this.pendingAuthRestoreState = nextState;
    this.setData(nextState);
  },

  showDeleteCurrentImageAction() {
    wx.showActionSheet({
      itemList: ["删除图片"],
      success: (res) => {
        if (res.tapIndex === 0) this.deleteCurrentImage();
      }
    });
  },

  deleteCurrentImage() {
    if (!this.data.selectedImages.length || this.data.processing) return;

    this.clearPollTimer();
    this.downloadingImageUrls = {};
    const selectedImages = this.data.selectedImages.filter((image, index) => index !== this.data.currentImageIndex);
    if (!selectedImages.length) {
      const nextState = {
        inputPath: "",
        selectedImages: [],
        currentImageIndex: 0,
        rotationDegrees: 0,
        previewRotationStyle: "",
        extractedImages: [],
        processing: false,
        expectedPolaroidCount: "",
        showCountInput: false,
        statusText: "请选择一张包含拍立得的图片",
        statusKind: "idle"
      };
      this.pendingAuthRestoreState = nextState;
      this.setData(nextState);
      return;
    }

    const currentImageIndex = Math.min(this.data.currentImageIndex, selectedImages.length - 1);
    const nextState = Object.assign(this.getCurrentImageState(selectedImages, currentImageIndex), {
      selectedImages,
      currentImageIndex,
      extractedImages: [],
      processing: false,
      showCountInput: true,
      statusText: selectedImages.length > 1
        ? `当前图片 ${currentImageIndex + 1}/${selectedImages.length}，点击开始提取`
        : "图片已选择，点击开始提取",
      statusKind: "ready"
    });
    this.pendingAuthRestoreState = nextState;
    this.setData(nextState);
  },

  onWhiteBalanceChange(event) {
    this.setData({
      wbEnabled: !!event.detail.value
    });
  },

  onDenoiseChange(event) {
    this.setData({
      denoiseEnabled: !!event.detail.value
    });
  },

  onExpectedCountInput(event) {
    const value = String(event.detail.value || "").replace(/\D/g, "").slice(0, 3);
    const selectedImages = this.updateCurrentSelectedImage({ expectedPolaroidCount: value });
    this.setData({
      expectedPolaroidCount: value,
      selectedImages
    });
  },

  rotateInputImage() {
    if (!this.data.inputPath || this.data.processing) return;

    const rotationDegrees = (this.data.rotationDegrees + 90) % 360;
    const previewRotationStyle = rotationDegrees ? `transform: rotate(${-rotationDegrees}deg);` : "";
    const selectedImages = this.updateCurrentSelectedImage({
      rotationDegrees,
      previewRotationStyle
    });
    this.setData({
      rotationDegrees,
      previewRotationStyle,
      selectedImages,
      extractedImages: [],
      statusText: "图片已选择，点击开始提取",
      statusKind: "ready"
    });
  },

  updateCurrentSelectedImage(patch) {
    if (!this.data.selectedImages.length) return [];
    return this.data.selectedImages.map((image, index) => {
      if (index !== this.data.currentImageIndex) return image;
      return Object.assign({}, image, patch);
    });
  },

  startExtract() {
    const processImages = this.getProcessImages();
    if (!processImages.length || this.data.processing) return;

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
    this.batchInterrupted = false;
    this.activeTaskId = "";
    this.activeBatchRunId += 1;
    const runId = this.activeBatchRunId;
    if (processImages.length > 1) {
      this.startBatchExtract(processImages, apiBaseUrl, token, runId);
      return;
    }

    this.startSingleExtract(processImages[0], apiBaseUrl, token, runId);
  },

  interruptBatchProcessing() {
    if (!this.data.processing) return;

    const taskId = this.activeTaskId;
    this.batchInterrupted = true;
    this.activeBatchRunId += 1;
    this.finishInterruptedProcessing(this.data.extractedImages);
    if (taskId) this.cancelBackendTask(taskId);
  },

  cancelBackendTask(taskId) {
    const apiBaseUrl = this.getApiBaseUrl();
    if (!apiBaseUrl || !taskId) return;

    wx.request({
      url: `${apiBaseUrl}/api/cancel/${encodeURIComponent(taskId)}`,
      method: "POST",
      header: this.getAuthHeader(),
      fail: (err) => {
        console.error("cancel task failed", err);
      }
    });
  },

  shouldIgnoreProcessingRun(runId) {
    return this.batchInterrupted || runId !== this.activeBatchRunId;
  },

  finishInterruptedProcessing(images) {
    this.clearPollTimer();
    const visibleImages = Array.isArray(images) ? images : this.data.extractedImages;
    this.activeTaskId = "";
    this.setData({
      extractedImages: visibleImages,
      processing: false,
      showCountInput: false,
      statusText: visibleImages.length
        ? `已中断处理，已保留 ${visibleImages.length} 张结果`
        : "已中断处理",
      statusKind: "error"
    });
  },

  getProcessImages() {
    if (this.data.selectedImages.length) return this.data.selectedImages.slice();
    if (!this.data.inputPath) return [];
    return [{
      path: this.data.inputPath,
      rotationDegrees: this.data.rotationDegrees || 0,
      expectedPolaroidCount: this.data.expectedPolaroidCount || ""
    }];
  },

  startSingleExtract(image, apiBaseUrl, token, runId) {
    const formData = {
      token,
      wb: this.data.wbEnabled ? "1" : "0",
      denoise: this.data.denoiseEnabled ? "1" : "0",
      rotation_degrees: String(image.rotationDegrees || 0)
    };
    const expectedCount = this.getExpectedPolaroidCount(image.expectedPolaroidCount);
    if (expectedCount) {
      formData.expected_polaroids = expectedCount;
      formData.polaroid_count = expectedCount;
    }
    this.activeTaskId = "";
    this.setData({
      processing: true,
      extractedImages: [],
      showCountInput: false,
      statusText: "正在上传图片...",
      statusKind: "processing"
    });

    wx.uploadFile({
      url: `${apiBaseUrl}/api/process`,
      filePath: image.path,
      name: "image",
      header: this.getAuthHeader(),
      formData,
      success: (res) => {
        if (this.shouldIgnoreProcessingRun(runId)) return;
        const payload = this.parseResponse(res.data);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          this.finishWithError(this.getResponseErrorMessage(res, payload, "Upload failed"));
          return;
        }
        if (!payload) {
          this.finishWithError(this.getResponseErrorMessage(res, payload, "Unexpected upload response"));
          return;
        }
        this.handleProcessPayload(payload, runId);
      },
      fail: (err) => {
        if (this.shouldIgnoreProcessingRun(runId)) return;
        console.error("uploadFile failed", err);
        this.finishWithError(this.getUploadErrorMessage(err));
      }
    });
  },

  startBatchExtract(processImages, apiBaseUrl, token, runId) {
    this.setData({
      processing: true,
      extractedImages: [],
      showCountInput: false,
      statusText: `正在处理图片 1/${processImages.length}，正在提取第1张`,
      statusKind: "processing"
    });
    this.processBatchImage(processImages, 0, [], [], apiBaseUrl, token, runId);
  },

  processBatchImage(processImages, imageIndex, accumulatedImages, failures, apiBaseUrl, token, runId) {
    if (this.shouldIgnoreProcessingRun(runId)) return;
    if (imageIndex >= processImages.length) {
      this.finishBatchExtract(accumulatedImages, failures, processImages.length);
      return;
    }

    const image = processImages[imageIndex];
    this.setData(Object.assign(this.getCurrentImageState(processImages, imageIndex), {
      currentImageIndex: imageIndex,
      statusText: this.getBatchProcessingStatusText(imageIndex, processImages.length, 0, this.getExpectedPolaroidCount(image.expectedPolaroidCount)),
      statusKind: "processing"
    }));

    this.uploadBatchImage(image, imageIndex, processImages.length, accumulatedImages, apiBaseUrl, token, runId, (result) => {
      if (this.shouldIgnoreProcessingRun(runId)) return;
      const nextImages = accumulatedImages.concat(result.images || []);
      const nextFailures = result.error
        ? failures.concat({ imageIndex, message: result.error })
        : failures;
      this.setData({ extractedImages: this.mergeImages(this.data.extractedImages, nextImages) });
      this.processBatchImage(processImages, imageIndex + 1, nextImages, nextFailures, apiBaseUrl, token, runId);
    });
  },

  uploadBatchImage(image, imageIndex, totalImages, baseImages, apiBaseUrl, token, runId, done) {
    if (this.shouldIgnoreProcessingRun(runId)) return;
    this.pollCount = 0;
    this.activeTaskId = "";
    const formData = {
      token,
      wb: this.data.wbEnabled ? "1" : "0",
      denoise: this.data.denoiseEnabled ? "1" : "0",
      rotation_degrees: String(image.rotationDegrees || 0)
    };
    const expectedCount = this.getExpectedPolaroidCount(image.expectedPolaroidCount);
    if (expectedCount) {
      formData.expected_polaroids = expectedCount;
      formData.polaroid_count = expectedCount;
    }

    wx.uploadFile({
      url: `${apiBaseUrl}/api/process`,
      filePath: image.path,
      name: "image",
      header: this.getAuthHeader(),
      formData,
      success: (res) => {
        if (this.shouldIgnoreProcessingRun(runId)) return;
        const payload = this.parseResponse(res.data);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          done({ error: this.getResponseErrorMessage(res, payload, "Upload failed") });
          return;
        }
        if (!payload) {
          done({ error: this.getResponseErrorMessage(res, payload, "Unexpected upload response") });
          return;
        }
        this.handleBatchProcessPayload(payload, imageIndex, totalImages, baseImages, runId, done);
      },
      fail: (err) => {
        if (this.shouldIgnoreProcessingRun(runId)) return;
        console.error("batch uploadFile failed", err);
        done({ error: this.getUploadErrorMessage(err) });
      }
    });
  },

  handleBatchProcessPayload(payload, imageIndex, totalImages, baseImages, runId, done) {
    if (this.shouldIgnoreProcessingRun(runId)) return;
    if (payload.error || payload.message && payload.status === "error") {
      done({ error: payload.error || payload.message });
      return;
    }

    const directImages = this.scopeBatchImages(this.normalizeImages(payload), imageIndex, `image${imageIndex + 1}`);
    if (directImages.length > 0) {
      this.setData({ extractedImages: this.mergeImages(baseImages, directImages) });
      done({ images: directImages });
      return;
    }

    const taskId = payload.task_id || payload.taskId || payload.id;
    if (taskId) {
      this.activeTaskId = taskId;
      this.setData({
        statusText: this.getBatchProcessingStatusText(imageIndex, totalImages, 0, 0),
        statusKind: "processing"
      });
      this.pollBatchTask(taskId, imageIndex, totalImages, baseImages, [], runId, done);
      return;
    }

    done({ error: "没有收到处理任务或结果图片" });
  },

  pollBatchTask(taskId, imageIndex, totalImages, baseImages, collectedImages, runId, done) {
    if (this.shouldIgnoreProcessingRun(runId)) return;
    this.clearPollTimer();
    this.pollTimer = setTimeout(() => {
      if (this.shouldIgnoreProcessingRun(runId)) return;
      this.pollCount += 1;
      if (this.pollCount > MAX_POLL_COUNT) {
        done({ images: collectedImages, error: "处理时间过长 请稍后重试" });
        return;
      }

      wx.request({
        url: `${this.getApiBaseUrl()}/api/status/${taskId}`,
        method: "GET",
        header: this.getAuthHeader(),
        success: (res) => {
          if (this.shouldIgnoreProcessingRun(runId)) return;
          const payload = res.data;
          if (res.statusCode < 200 || res.statusCode >= 300) {
            done({ images: collectedImages, error: this.getResponseErrorMessage(res, payload, "Status failed") });
            return;
          }
          if (!payload || typeof payload !== "object") {
            done({ images: collectedImages, error: this.getResponseErrorMessage(res, payload, "Unexpected status response") });
            return;
          }

          const status = payload.status || payload.state;
          const images = this.scopeBatchImages(this.normalizeImages(payload, taskId), imageIndex, taskId);
          const nextCollectedImages = this.mergeImages(collectedImages, images);
          const visibleImages = this.mergeImages(baseImages, nextCollectedImages);
          const expectedCount = this.getBackendExpectedCount(payload);
          const warning = payload.warning || payload.detection_warning || "";
          const extractionComplete = payload.extraction_complete === true
            || payload.done_marker === true
            || payload.complete === true;

          if (nextCollectedImages.length > collectedImages.length) {
            this.setData({ extractedImages: visibleImages });
            this.prefetchResultImages(visibleImages);
          }

          if (extractionComplete) {
            this.activeTaskId = "";
            if (expectedCount > 0 && nextCollectedImages.length !== expectedCount) {
              done({
                images: nextCollectedImages,
                error: `结果传输不完整：已收到 ${nextCollectedImages.length}/${expectedCount} 张`
              });
            } else if (nextCollectedImages.length > 0) {
              done({ images: nextCollectedImages, warning });
            } else {
              done({ error: warning || "处理结束，但未提取到拍立得" });
            }
            return;
          }

          if (status === "canceled" || status === "cancelled") {
            this.batchInterrupted = true;
            this.activeBatchRunId += 1;
            this.finishInterruptedProcessing(visibleImages);
            return;
          }

          if (status === "done" || status === "finished" || status === "success") {
            this.activeTaskId = "";
            done({ images: nextCollectedImages, error: "处理状态缺少结束标记" });
            return;
          }

          if (status === "failed" || status === "error") {
            this.activeTaskId = "";
            done({ images: nextCollectedImages, error: payload.error || payload.message || "处理失败" });
            return;
          }

          this.setData({
            statusText: this.getBatchProcessingStatusText(imageIndex, totalImages, nextCollectedImages.length, expectedCount, warning),
            statusKind: "processing"
          });
          this.pollBatchTask(taskId, imageIndex, totalImages, baseImages, nextCollectedImages, runId, done);
        },
        fail: (err) => {
          if (this.shouldIgnoreProcessingRun(runId)) return;
          console.error("batch status request failed", err);
          done({ images: collectedImages, error: "查询处理状态失败" });
        }
      });
    }, POLL_INTERVAL_MS);
  },

  scopeBatchImages(images, imageIndex, taskId) {
    return images.map((image, index) => {
      const resultId = Object.prototype.hasOwnProperty.call(image, "id") ? image.id : `p${index + 1}`;
      const scopedId = `${taskId}:${resultId}`;
      return Object.assign({}, image, {
        id: scopedId,
        sourceImageIndex: imageIndex,
        title: `图片${imageIndex + 1} ${image.title || `拍立得${index + 1}`}`
      });
    });
  },

  finishBatchExtract(images, failures, totalImages) {
    this.clearPollTimer();
    this.activeTaskId = "";
    const hasImages = images.length > 0;
    const statusText = hasImages
      ? failures.length
        ? `批量处理完成，提取 ${images.length} 张，${failures.length}/${totalImages} 张图片失败`
        : `批量处理完成，共提取 ${images.length} 张`
      : `批量处理失败，${failures.length || totalImages}/${totalImages} 张图片未提取到结果`;
    this.setData({
      extractedImages: images,
      processing: false,
      showCountInput: false,
      statusText,
      statusKind: hasImages ? "done" : "error"
    });
    if (hasImages) {
      this.prefetchResultImages(images);
    } else {
      wx.showToast({ title: "批量处理失败", icon: "none" });
    }
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

  getExpectedPolaroidCount(rawValue = this.data.expectedPolaroidCount) {
    const value = parseInt(rawValue, 10);
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

  handleProcessPayload(payload, runId) {
    if (this.shouldIgnoreProcessingRun(runId)) return;
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
      this.activeTaskId = taskId;
      this.setData({
        statusText: "图片处理中...",
        statusKind: "processing"
      });
      this.pollTask(taskId, runId);
      return;
    }

    this.finishWithError("没有收到处理任务或结果图片");
  },

  pollTask(taskId, runId) {
    if (this.shouldIgnoreProcessingRun(runId)) return;
    this.clearPollTimer();
    this.pollTimer = setTimeout(() => {
      if (this.shouldIgnoreProcessingRun(runId)) return;
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
          if (this.shouldIgnoreProcessingRun(runId)) return;
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
          const expectedCount = this.getBackendExpectedCount(payload);
          const warning = payload.warning || payload.detection_warning || "";
          const extractionComplete = payload.extraction_complete === true
            || payload.done_marker === true
            || payload.complete === true;

          if (extractionComplete) {
            this.activeTaskId = "";
            const completedImages = this.mergeImages(this.data.extractedImages, images);
            if (expectedCount > 0 && completedImages.length !== expectedCount) {
              this.finishWithError(`结果传输不完整：已收到 ${completedImages.length}/${expectedCount} 张`);
            } else if (completedImages.length > 0) {
              this.finishWithImages(completedImages, warning);
            } else if (warning) {
              this.finishWithNotice(warning);
            } else {
              this.finishWithError("处理结束，但未提取到拍立得");
            }
            return;
          }

          if (status === "canceled" || status === "cancelled") {
            this.batchInterrupted = true;
            this.activeBatchRunId += 1;
            this.finishInterruptedProcessing(this.data.extractedImages);
            return;
          }

          if (status === "done" || status === "finished" || status === "success") {
            this.activeTaskId = "";
            this.finishWithError("处理状态缺少结束标记");
            return;
          }

          if (status === "failed" || status === "error") {
            this.activeTaskId = "";
            this.finishWithError(payload.error || payload.message || "处理失败");
            return;
          }

          this.setData({
            statusText: this.getProcessingStatusText(images.length, expectedCount, warning),
            statusKind: "processing"
          });
          this.pollTask(taskId, runId);
        },
        fail: (err) => {
          if (this.shouldIgnoreProcessingRun(runId)) return;
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

  getBackendExpectedCount(payload) {
    const totalCount = Number(payload.total_polaroids || 0);
    if (totalCount > 0) return totalCount;

    const phase = payload.phase || "";
    const hasFinalizedTarget = payload.extraction_complete === true
      || phase === "extracting"
      || phase === "complete";
    const expectedCount = hasFinalizedTarget ? Number(payload.expected_polaroids || 0) : 0;
    return expectedCount > 0 ? expectedCount : 0;
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
    const targetCount = Number(expectedCount || 0);
    const nextIndex = targetCount > 0
      ? Math.max(1, Math.min(doneCount + 1, targetCount))
      : doneCount + 1;
    const countText = targetCount > 0 ? ` (${nextIndex}/${targetCount})` : "";
    const statusText = `正在提取第${nextIndex}张${countText}`;
    return warning ? `${statusText}，${warning}` : statusText;
  },

  getBatchProcessingStatusText(imageIndex, totalImages, doneCount, expectedCount, warning) {
    return `正在处理图片 ${imageIndex + 1}/${totalImages}，${this.getProcessingStatusText(doneCount, expectedCount, warning)}`;
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
    this.activeTaskId = "";
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
    this.activeTaskId = "";
    this.setData({
      processing: false,
      statusText: message || "处理结束",
      statusKind: "done"
    });
  },

  finishWithError(message) {
    this.clearPollTimer();
    this.activeTaskId = "";
    this.setData({
      processing: false,
      statusText: message || "处理失败",
      statusKind: "error"
    });
    wx.showToast({ title: message || "处理失败", icon: "none" });
  },

  contactAuthor() {
    this.setData({
      showContactDialog: true,
      contactMessage: "",
      contactInfo: "",
      contactSubmitting: false
    });
  },

  createSelectedImage(path) {
    return {
      id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      path,
      rotationDegrees: 0,
      previewRotationStyle: "",
      expectedPolaroidCount: ""
    };
  },

  getCurrentImageState(selectedImages, currentImageIndex) {
    const currentImage = selectedImages[currentImageIndex] || {};
    return {
      inputPath: currentImage.path || "",
      rotationDegrees: currentImage.rotationDegrees || 0,
      previewRotationStyle: currentImage.previewRotationStyle || "",
      expectedPolaroidCount: currentImage.expectedPolaroidCount || ""
    };
  },

  noop() {},

  onContactMessageInput(event) {
    this.setData({
      contactMessage: String(event.detail.value || "").slice(0, CONTACT_MESSAGE_MAX_LENGTH)
    });
  },

  onContactInfoInput(event) {
    this.setData({
      contactInfo: String(event.detail.value || "").slice(0, CONTACT_INFO_MAX_LENGTH)
    });
  },

  cancelContactDialog() {
    if (this.data.contactSubmitting) return;
    this.resetContactDialogState();
  },

  resetContactDialogState() {
    this.setData({
      showContactDialog: false,
      contactMessage: "",
      contactInfo: "",
      contactSubmitting: false
    });
  },

  submitContactDialog() {
    if (this.data.contactSubmitting) return;

    const message = (this.data.contactMessage || "").trim();
    const contact = (this.data.contactInfo || "").trim();
    if (!message) {
      wx.showToast({ title: "请输入内容", icon: "none" });
      return;
    }

    this.sendContactMessage(message, contact);
  },

  sendContactMessage(message, contact) {
    const apiBaseUrl = this.getApiBaseUrl();
    const token = this.getAuthToken();
    if (!apiBaseUrl || isLocalPreviewToken(token)) {
      wx.showToast({ title: "请先使用有效 Token", icon: "none" });
      return;
    }

    this.setData({ contactSubmitting: true });
    wx.request({
      url: `${apiBaseUrl}/api/contact`,
      method: "POST",
      header: Object.assign({
        "content-type": "application/json"
      }, this.getAuthHeader()),
      data: { message, contact },
      success: (res) => {
        const ok = res.statusCode >= 200
          && res.statusCode < 300
          && res.data
          && (res.data.ok === true || res.data.status === "sent");
        if (ok) {
          this.resetContactDialogState();
          wx.showToast({ title: "已发送", icon: "success" });
          return;
        }
        this.setData({ contactSubmitting: false });
        wx.showToast({
          title: (res.data && (res.data.error || res.data.message)) || "发送失败，请稍后重试",
          icon: "none"
        });
      },
      fail: () => {
        this.setData({ contactSubmitting: false });
        wx.showToast({ title: "发送失败，请稍后重试", icon: "none" });
      }
    });
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
