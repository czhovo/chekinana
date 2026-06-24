const { AUTH_STORAGE_KEY, SCANNER_AUTH_PASSED_KEY, getApiBaseUrl, isLocalPreviewToken } = require("../../utils/config");
const POLL_INTERVAL_MS = 1000;
const MAX_POLL_COUNT = 180;
const MAX_SELECTED_IMAGES = 9;
const CONTACT_MESSAGE_MAX_LENGTH = 1000;
const CONTACT_INFO_MAX_LENGTH = 200;
const UPLOAD_TIMEOUT_MS = 15000;
const UPLOAD_MAX_RETRIES = 3;
const RESULT_DOWNLOAD_MAX_CONCURRENCY = 3;
const RESULT_DOWNLOAD_MAX_RETRIES = 1;
const RESULT_SAVE_MAX_RETRIES = 1;
const RESULT_SAVE_OPERATION_TIMEOUT_MS = 15000;
const PRE_TASK_UPLOAD_CANCEL_PATH = "/api/upload-cancel";
const POLAROID_SIZE_OPTIONS = ["auto", "mini", "wide"];
const DEFAULT_POLAROID_SIZE = "mini";
const POSTPROCESS_MODE_OPTIONS = ["off", "denoise", "sharpen"];
const DEFAULT_POSTPROCESS_MODE = "denoise";
const RESULT_SAVE_STATUS_UNKNOWN = "unknown";
const RESULT_SAVE_STATUS_SAVING = "saving";
const RESULT_SAVE_STATUS_SAVED = "saved";
const RESULT_SAVE_STATUS_FAILED = "failed";
const RESULT_DOWNLOAD_STATUS_UNKNOWN = "unknown";
const RESULT_DOWNLOAD_STATUS_PENDING = "pending";
const RESULT_DOWNLOAD_STATUS_DOWNLOADING = "downloading";
const RESULT_DOWNLOAD_STATUS_DOWNLOADED = "downloaded";
const RESULT_DOWNLOAD_STATUS_FAILED = "failed";

Page({
  data: {
    inputPath: "",
    currentPreviewImages: [],
    selectedImages: [],
    currentImageIndex: 0,
    rotationDegrees: 0,
    polaroidSize: DEFAULT_POLAROID_SIZE,
    extractedImages: [],
    processing: false,
    wbEnabled: true,
    postprocessMode: DEFAULT_POSTPROCESS_MODE,
    expectedPolaroidCount: "",
    showCountInput: false,
    showContactDialog: false,
    contactMessage: "",
    contactInfo: "",
    contactSubmitting: false,
    failedImageIndexes: [],
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
  activeUploadTask: null,
  activeUploadAttemptId: "",
  activeUploadTimer: null,
  batchInterrupted: false,
  resultDownloadQueue: [],
  activeResultDownloadCount: 0,
  queuedResultDownloadKeys: {},

  onUnload() {
    this.clearPollTimer();
    this.clearActiveUploadAttempt();
  },

  onShow() {
    this.setTabBarSelected(0);
    const token = this.getAuthToken();
    if (!token) {
      wx.removeStorageSync(SCANNER_AUTH_PASSED_KEY);
      wx.redirectTo({ url: "/pages/auth/auth" });
    }
  },

  setTabBarSelected(selected) {
    if (typeof this.getTabBar !== "function") return;
    const tabBar = this.getTabBar();
    if (tabBar) tabBar.setData({ selected });
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
        currentPreviewImages: this.data.currentPreviewImages.length
          ? this.data.currentPreviewImages
          : this.getCurrentPreviewImages(this.data.selectedImages, this.data.currentImageIndex),
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
    wx.removeStorageSync(SCANNER_AUTH_PASSED_KEY);
    this.clearPollTimer();
    this.downloadingImageUrls = {};
    this.setData({
      processing: false,
      inputPath: "",
      currentPreviewImages: [],
      selectedImages: [],
      currentImageIndex: 0,
      rotationDegrees: 0,
      polaroidSize: DEFAULT_POLAROID_SIZE,
      extractedImages: [],
      failedImageIndexes: [],
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

    if (typeof wx.chooseImage === "function") {
      wx.chooseImage({
        count: remainingCount,
        sourceType: ["album", "camera"],
        sizeType: ["original"],
        success: (res) => {
          this.handleImagePickerSuccess(this.normalizeImagePickerPaths(res), remainingCount);
        },
        fail: (err) => {
          this.handleImagePickerFailure(err, "chooseImage");
        }
      });
      return;
    }

    this.chooseImageWithMediaFallback(remainingCount);
  },

  chooseImageWithMediaFallback(remainingCount) {
    wx.chooseMedia({
      count: remainingCount,
      mediaType: ["image"],
      sourceType: ["album", "camera"],
      sizeType: ["original"],
      success: (res) => {
        this.handleImagePickerSuccess(this.normalizeImagePickerPaths(res), remainingCount);
      },
      fail: (err) => {
        this.handleImagePickerFailure(err, "chooseMedia");
      }
    });
  },

  normalizeImagePickerPaths(res) {
    const paths = [];
    (res && res.tempFilePaths || []).forEach((path) => {
      if (path) paths.push(path);
    });
    (res && res.tempFiles || []).forEach((file) => {
      const path = file && (file.tempFilePath || file.path);
      if (path) paths.push(path);
    });
    return paths.filter((path, index) => paths.indexOf(path) === index);
  },

  handleImagePickerSuccess(paths, remainingCount) {
    const selectedPaths = (paths || []).filter(Boolean).slice(0, remainingCount);
    if (!selectedPaths.length) {
      wx.showToast({ title: "未选择图片", icon: "none" });
      return;
    }

    this.clearPollTimer();
    this.downloadingImageUrls = {};
    const selectedImages = this.data.selectedImages.concat(
      selectedPaths.map((path) => this.createSelectedImage(path))
    );
    const currentImageIndex = this.data.selectedImages.length ? this.data.currentImageIndex : 0;
    const nextState = Object.assign(this.getCurrentImageState(selectedImages, currentImageIndex), {
      selectedImages,
      currentImageIndex,
      extractedImages: [],
      failedImageIndexes: [],
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

  handleImagePickerFailure(err, pickerName) {
    if (this.isImagePickerCancel(err)) return;
    console.error(`${pickerName || "image picker"} failed`, err);
    wx.showToast({ title: "选择图片失败，请重试", icon: "none" });
  },

  isImagePickerCancel(err) {
    const errMsg = err && err.errMsg ? String(err.errMsg).toLowerCase() : "";
    return errMsg.includes("cancel");
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
    const hasCompletedActionState = this.hasCompletedActionState();
    const nextState = Object.assign(this.getCurrentImageState(selectedImages, clampedIndex), {
      currentImageIndex: clampedIndex,
      showCountInput: !this.data.processing && !hasCompletedActionState
    });
    if (!this.data.processing && !hasCompletedActionState) {
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

  hasCompletedActionState() {
    return !this.data.processing
      && ((this.data.extractedImages || []).length > 0 || (this.data.failedImageIndexes || []).length > 0);
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
    if (this.hasCompletedActionState()) {
      this.deleteCompletedCurrentImage();
      return;
    }

    this.clearPollTimer();
    this.downloadingImageUrls = {};
    const deletedImage = this.data.selectedImages[this.data.currentImageIndex];
    this.cleanupRemovedSourceGroups([{
      sourceImage: deletedImage,
      results: []
    }]);
    const selectedImages = this.data.selectedImages.filter((image, index) => index !== this.data.currentImageIndex);
    if (!selectedImages.length) {
      const nextState = {
        inputPath: "",
        currentPreviewImages: [],
        selectedImages: [],
        currentImageIndex: 0,
        rotationDegrees: 0,
        polaroidSize: DEFAULT_POLAROID_SIZE,
        extractedImages: [],
        failedImageIndexes: [],
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
      failedImageIndexes: [],
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

  deleteCompletedCurrentImage() {
    this.clearPollTimer();
    this.downloadingImageUrls = {};
    const deletedIndex = this.data.currentImageIndex;
    const removedGroups = this.getSourceCleanupGroups([deletedIndex]);
    const selectedImages = this.data.selectedImages.filter((image, index) => index !== deletedIndex);
    if (!selectedImages.length) {
      this.resetAllImagesState();
      return;
    }
    this.cleanupRemovedSourceGroups(removedGroups);

    const oldToNewIndex = {};
    selectedImages.forEach((image, index) => {
      const oldIndex = index >= deletedIndex ? index + 1 : index;
      oldToNewIndex[oldIndex] = index;
    });
    const extractedImages = (this.data.extractedImages || [])
      .filter((image) => this.getResultSourceIndex(image) !== deletedIndex)
      .map((image) => Object.assign({}, image, {
        sourceImageIndex: oldToNewIndex[this.getResultSourceIndex(image)]
      }));
    const failedImageIndexes = (this.data.failedImageIndexes || [])
      .filter((index) => index !== deletedIndex)
      .map((index) => oldToNewIndex[index])
      .filter((index) => Number.isInteger(index));
    const currentImageIndex = Math.min(deletedIndex, selectedImages.length - 1);
    const hasCompletedArtifacts = extractedImages.length > 0 || failedImageIndexes.length > 0;
    const nextState = Object.assign(this.getCurrentImageState(selectedImages, currentImageIndex), {
      selectedImages,
      currentImageIndex,
      extractedImages,
      failedImageIndexes,
      processing: false,
      showCountInput: !hasCompletedArtifacts,
      statusText: hasCompletedArtifacts
        ? this.data.statusText
        : selectedImages.length > 1
          ? `当前图片 ${currentImageIndex + 1}/${selectedImages.length}，点击开始提取`
          : "图片已选择，点击开始提取",
      statusKind: hasCompletedArtifacts ? this.data.statusKind : "ready"
    });
    this.pendingAuthRestoreState = nextState;
    this.setData(nextState);
  },

  onWhiteBalanceChange(event) {
    this.setData({
      wbEnabled: !!event.detail.value
    });
  },

  onPostprocessModeChange(event) {
    if (this.data.processing) return;

    this.setData({
      postprocessMode: this.getValidPostprocessMode(event.currentTarget.dataset.mode)
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

  onPolaroidSizeChange(event) {
    if (this.data.processing) return;

    const polaroidSize = this.getValidPolaroidSize(event.currentTarget.dataset.size);
    if (polaroidSize === this.data.polaroidSize) return;

    const selectedImages = this.updateCurrentSelectedImage({ polaroidSize });
    this.setData({
      polaroidSize,
      selectedImages,
      extractedImages: [],
      failedImageIndexes: [],
      statusKind: "ready"
    });
  },

  rotateInputImage() {
    if (!this.data.inputPath || this.data.processing) return;

    const rotationDegrees = (this.data.rotationDegrees + 90) % 360;
    const currentImageIndex = this.data.currentImageIndex;
    const currentImage = this.data.selectedImages[currentImageIndex] || {};
    const sourcePath = currentImage.path || currentImage.previewPath || this.data.inputPath;
    const selectedImages = this.updateCurrentSelectedImage({
      rotationDegrees,
      previewPath: sourcePath,
      previewRotationDegrees: rotationDegrees
    });
    this.setData({
      inputPath: sourcePath,
      currentPreviewImages: this.getCurrentPreviewImages(selectedImages, currentImageIndex),
      rotationDegrees,
      selectedImages,
      extractedImages: [],
      failedImageIndexes: [],
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
      wx.removeStorageSync(SCANNER_AUTH_PASSED_KEY);
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
    this.setData({ failedImageIndexes: [] });
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
    this.cancelActiveUploadAttempt();
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

  cancelActiveUploadAttempt() {
    const uploadTask = this.activeUploadTask;
    const uploadAttemptId = this.activeUploadAttemptId;
    if (uploadTask && typeof uploadTask.abort === "function") {
      uploadTask.abort();
    }
    this.clearActiveUploadAttempt(uploadAttemptId);
    if (uploadAttemptId) this.cancelUploadAttempt(uploadAttemptId);
  },

  cancelUploadAttempt(uploadAttemptId) {
    const apiBaseUrl = this.getApiBaseUrl();
    if (!apiBaseUrl || !uploadAttemptId) return;

    wx.request({
      url: `${apiBaseUrl}${PRE_TASK_UPLOAD_CANCEL_PATH}/${encodeURIComponent(uploadAttemptId)}`,
      method: "POST",
      header: Object.assign({ "content-type": "application/json" }, this.getAuthHeader()),
      data: { upload_attempt_id: uploadAttemptId },
      fail: (err) => {
        console.error("cancel upload attempt failed", err);
      }
    });
  },

  clearActiveUploadAttempt(uploadAttemptId) {
    if (uploadAttemptId && this.activeUploadAttemptId && uploadAttemptId !== this.activeUploadAttemptId) return;
    if (this.activeUploadTimer) {
      clearTimeout(this.activeUploadTimer);
    }
    this.activeUploadTimer = null;
    this.activeUploadTask = null;
    this.activeUploadAttemptId = "";
  },

  shouldIgnoreProcessingRun(runId) {
    return this.batchInterrupted || runId !== this.activeBatchRunId;
  },

  finishInterruptedProcessing(images) {
    this.clearPollTimer();
    const visibleImages = Array.isArray(images) ? images : this.data.extractedImages;
    const extractedImages = this.mergeWithLatestResultState(visibleImages);
    this.activeTaskId = "";
    this.setData({
      extractedImages,
      processing: false,
      showCountInput: false,
      statusText: extractedImages.length
        ? `已中断处理，已保留 ${extractedImages.length} 张结果`
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
      polaroidSize: this.getValidPolaroidSize(this.data.polaroidSize),
      expectedPolaroidCount: this.data.expectedPolaroidCount || ""
    }];
  },

  startSingleExtract(image, apiBaseUrl, token, runId) {
    const formData = {
      token,
      wb: this.data.wbEnabled ? "1" : "0",
      denoise: this.getDenoiseFormValue(this.data.postprocessMode),
      postprocess_mode: this.getValidPostprocessMode(this.data.postprocessMode),
      rotation_degrees: String(image.rotationDegrees || 0),
      polaroid_size: this.getValidPolaroidSize(image.polaroidSize)
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
      statusText: "图片上传中",
      statusKind: "processing"
    });

    this.uploadImageWithRetry(image, formData, apiBaseUrl, runId, "图片上传中", (result) => {
      if (this.shouldIgnoreProcessingRun(runId)) return;
      if (result.error) {
        this.finishWithError(result.error);
        return;
      }
      this.handleProcessPayload(result.payload, runId, Number(expectedCount || 0));
    });
  },

  startBatchExtract(processImages, apiBaseUrl, token, runId) {
    this.setData({
      processing: true,
      extractedImages: [],
      showCountInput: false,
      statusText: this.getUploadStatusText(0, processImages.length),
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
      statusText: this.getUploadStatusText(imageIndex, processImages.length),
      statusKind: "processing"
    }));

    this.uploadBatchImage(image, imageIndex, processImages.length, accumulatedImages, apiBaseUrl, token, runId, (result) => {
      if (this.shouldIgnoreProcessingRun(runId)) return;
      const nextImages = accumulatedImages.concat(result.images || []);
      const nextFailures = result.error
        ? failures.concat({ imageIndex, message: result.error })
        : failures;
      this.setExtractedImagesPreservingState(nextImages);
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
      denoise: this.getDenoiseFormValue(this.data.postprocessMode),
      postprocess_mode: this.getValidPostprocessMode(this.data.postprocessMode),
      rotation_degrees: String(image.rotationDegrees || 0),
      polaroid_size: this.getValidPolaroidSize(image.polaroidSize)
    };
    const expectedCount = this.getExpectedPolaroidCount(image.expectedPolaroidCount);
    if (expectedCount) {
      formData.expected_polaroids = expectedCount;
      formData.polaroid_count = expectedCount;
    }

    this.uploadImageWithRetry(image, formData, apiBaseUrl, runId, this.getUploadStatusText(imageIndex, totalImages), (result) => {
      if (this.shouldIgnoreProcessingRun(runId)) return;
      if (result.error) {
        done({ error: result.error });
        return;
      }
      this.handleBatchProcessPayload(result.payload, imageIndex, totalImages, baseImages, runId, Number(expectedCount || 0), done);
    });
  },

  uploadImageWithRetry(image, formData, apiBaseUrl, runId, uploadStatusText, done) {
    const startAttempt = (retryCount) => {
      if (this.shouldIgnoreProcessingRun(runId)) return;

      const uploadAttemptId = this.createUploadAttemptId();
      const attemptFormData = Object.assign({}, formData, {
        upload_attempt_id: uploadAttemptId
      });
      let settled = false;
      this.activeUploadAttemptId = uploadAttemptId;
      this.setData({
        statusText: retryCount > 0
          ? `${uploadStatusText}，重试 ${retryCount}/${UPLOAD_MAX_RETRIES}`
          : uploadStatusText,
        statusKind: "processing"
      });
      this.activeUploadTimer = setTimeout(() => {
        if (settled || this.shouldIgnoreProcessingRun(runId)) return;
        settled = true;
        const uploadTask = this.activeUploadTask;
        if (uploadTask && typeof uploadTask.abort === "function") {
          uploadTask.abort();
        }
        this.clearActiveUploadAttempt(uploadAttemptId);
        this.cancelUploadAttempt(uploadAttemptId);
        if (retryCount < UPLOAD_MAX_RETRIES) {
          startAttempt(retryCount + 1);
          return;
        }
        done({ error: `图片上传超时，请稍后重试（已重试 ${UPLOAD_MAX_RETRIES} 次）` });
      }, UPLOAD_TIMEOUT_MS);

      const uploadTask = wx.uploadFile({
        url: `${apiBaseUrl}/api/process`,
        filePath: image.path,
        name: "image",
        header: this.getAuthHeader(),
        formData: attemptFormData,
        success: (res) => {
          if (settled || this.shouldIgnoreProcessingRun(runId)) return;
          settled = true;
          this.clearActiveUploadAttempt(uploadAttemptId);
          const payload = this.parseResponse(res.data);
          if (res.statusCode < 200 || res.statusCode >= 300) {
            done({ error: this.getResponseErrorMessage(res, payload, "Upload failed") });
            return;
          }
          if (!payload) {
            done({ error: this.getResponseErrorMessage(res, payload, "Unexpected upload response") });
            return;
          }
          done({ payload });
        },
        fail: (err) => {
          if (settled || this.shouldIgnoreProcessingRun(runId)) return;
          settled = true;
          this.clearActiveUploadAttempt(uploadAttemptId);
          this.cancelUploadAttempt(uploadAttemptId);
          console.error("uploadFile failed", err);
          if (retryCount < UPLOAD_MAX_RETRIES) {
            startAttempt(retryCount + 1);
            return;
          }
          done({ error: this.getUploadErrorMessage(err) });
        }
      });
      if (!settled && this.activeUploadAttemptId === uploadAttemptId) {
        this.activeUploadTask = uploadTask || null;
      }
    };

    startAttempt(0);
  },

  createUploadAttemptId() {
    return `upload-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  },

  handleBatchProcessPayload(payload, imageIndex, totalImages, baseImages, runId, fallbackExpectedCount, done) {
    if (this.shouldIgnoreProcessingRun(runId)) return;
    if (payload.error || payload.message && payload.status === "error") {
      done({ error: payload.error || payload.message });
      return;
    }

    const directImages = this.scopeBatchImages(this.normalizeImages(payload), imageIndex, `image${imageIndex + 1}`);
    if (directImages.length > 0) {
      this.setExtractedImagesPreservingState(this.mergeImages(baseImages, directImages));
      const expectedCount = this.getExpectedPolaroidTarget(payload, fallbackExpectedCount);
      done({
        images: directImages,
        error: expectedCount > 0 && directImages.length < expectedCount
          ? this.getShortageStatusText(directImages.length, expectedCount)
          : ""
      });
      return;
    }

    const taskId = payload.task_id || payload.taskId || payload.id;
    if (taskId) {
      this.activeTaskId = taskId;
      this.setData({
        statusText: this.getQueuedStatusText(imageIndex, totalImages, payload, taskId),
        statusKind: "processing"
      });
      this.pollBatchTask(taskId, imageIndex, totalImages, baseImages, [], runId, fallbackExpectedCount, done);
      return;
    }

    done({ error: "没有收到处理任务或结果图片" });
  },

  pollBatchTask(taskId, imageIndex, totalImages, baseImages, collectedImages, runId, fallbackExpectedCount, done) {
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
          const visibleImages = this.mergeWithLatestResultState(this.mergeImages(baseImages, nextCollectedImages));
          const expectedCount = this.getExpectedPolaroidTarget(payload, fallbackExpectedCount);
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
            if (expectedCount > 0 && nextCollectedImages.length < expectedCount) {
              done({
                images: nextCollectedImages,
                error: this.getShortageStatusText(nextCollectedImages.length, expectedCount)
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

          if (this.isAnotherTaskActive(payload, taskId) && nextCollectedImages.length === collectedImages.length) {
            this.setData({
              statusText: this.getQueuedStatusText(imageIndex, totalImages, payload, taskId),
              statusKind: "processing"
            });
            this.pollBatchTask(taskId, imageIndex, totalImages, baseImages, nextCollectedImages, runId, fallbackExpectedCount, done);
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

          if (this.isCurrentTaskActive(payload, taskId)) {
            this.setData({
              statusText: this.getActiveTaskStatusText(imageIndex, totalImages, taskId, payload, nextCollectedImages.length, expectedCount, warning),
              statusKind: "processing"
            });
            this.pollBatchTask(taskId, imageIndex, totalImages, baseImages, nextCollectedImages, runId, fallbackExpectedCount, done);
            return;
          }

          this.setData({
            statusText: this.getQueuedStatusText(imageIndex, totalImages, payload, taskId),
            statusKind: "processing"
          });
          this.pollBatchTask(taskId, imageIndex, totalImages, baseImages, nextCollectedImages, runId, fallbackExpectedCount, done);
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
    const mergedImages = this.mergeWithLatestResultState(images);
    const hasImages = mergedImages.length > 0;
    const shortageText = this.getShortageSummaryText(failures);
    const statusText = hasImages
      ? shortageText
        ? `批量处理完成，共提取 ${mergedImages.length} 张，${shortageText}`
        : failures.length
          ? `批量处理完成，提取 ${mergedImages.length} 张，${failures.length}/${totalImages} 张图片失败`
          : `批量处理完成，共提取 ${mergedImages.length} 张`
      : shortageText
        ? `批量处理完成，${shortageText}`
        : `批量处理失败，${failures.length || totalImages}/${totalImages} 张图片未提取到结果`;
    const statusKind = hasImages
      ? shortageText || failures.length
        ? "error"
        : "done"
      : "error";
    this.setData({
      extractedImages: mergedImages,
      failedImageIndexes: failures.map((failure) => failure.imageIndex),
      processing: false,
      showCountInput: false,
      statusText,
      statusKind
    });
    if (hasImages) {
      this.prefetchResultImages(mergedImages);
    } else {
      wx.showToast({ title: "批量处理失败", icon: "none" });
    }
  },

  getShortageSummaryText(failures) {
    return failures
      .filter((failure) => failure && failure.message && failure.message.includes("结果不足"))
      .map((failure) => `图片${failure.imageIndex + 1}${failure.message}`)
      .join("；");
  },

  getShortageStatusText(receivedCount, expectedCount) {
    return `结果不足：已收到 ${receivedCount}/${expectedCount} 张`;
  },

  getUploadErrorMessage(err) {
    const errMsg = err && err.errMsg ? err.errMsg : "";
    const normalizedErrMsg = errMsg.toLowerCase();
    if (
      normalizedErrMsg.includes("socket")
      || normalizedErrMsg.includes("tls")
      || normalizedErrMsg.includes("ssl")
      || normalizedErrMsg.includes("secure")
    ) {
      return "图片上传失败，请检查网络后重试";
    }
    if (errMsg.includes("url not in domain list") || errMsg.includes("domain list")) {
      return `上传域名未配置到微信合法域名：${errMsg}`;
    }
    if (errMsg.includes("timeout")) {
      return "处理时间过长 请稍后重试";
    }
    if (errMsg.includes("fail")) {
      return "图片上传失败，请检查网络后重试";
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

  handleProcessPayload(payload, runId, fallbackExpectedCount = 0) {
    if (this.shouldIgnoreProcessingRun(runId)) return;
    if (payload.error || payload.message && payload.status === "error") {
      this.finishWithError(payload.error || payload.message);
      return;
    }

    const images = this.normalizeImages(payload);
    if (images.length > 0) {
      const expectedCount = this.getExpectedPolaroidTarget(payload, fallbackExpectedCount);
      if (expectedCount > 0 && images.length < expectedCount) {
        this.finishWithShortage(images, images.length, expectedCount);
      } else {
        this.finishWithImages(images);
      }
      return;
    }

    const taskId = payload.task_id || payload.taskId || payload.id;
    if (taskId) {
      this.activeTaskId = taskId;
      this.setData({
        statusText: this.getQueuedStatusText(null, null, payload, taskId),
        statusKind: "processing"
      });
      this.pollTask(taskId, runId, fallbackExpectedCount);
      return;
    }

    this.finishWithError("没有收到处理任务或结果图片");
  },

  pollTask(taskId, runId, fallbackExpectedCount = 0) {
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
          const expectedCount = this.getExpectedPolaroidTarget(payload, fallbackExpectedCount);
          const warning = payload.warning || payload.detection_warning || "";
          const extractionComplete = payload.extraction_complete === true
            || payload.done_marker === true
            || payload.complete === true;

          if (extractionComplete) {
            this.activeTaskId = "";
            const completedImages = this.mergeImages(this.data.extractedImages, images);
            if (expectedCount > 0 && completedImages.length < expectedCount) {
              this.finishWithShortage(completedImages, completedImages.length, expectedCount);
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

          if (this.isAnotherTaskActive(payload, taskId) && images.length === 0) {
            this.setData({
              statusText: this.getQueuedStatusText(null, null, payload, taskId),
              statusKind: "processing"
            });
            this.pollTask(taskId, runId, fallbackExpectedCount);
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

          if (this.isCurrentTaskActive(payload, taskId)) {
            this.setData({
              statusText: this.getActiveTaskStatusText(null, null, taskId, payload, images.length, expectedCount, warning),
              statusKind: "processing"
            });
            this.pollTask(taskId, runId, fallbackExpectedCount);
            return;
          }

          this.setData({
            statusText: this.getQueuedStatusText(null, null, payload, taskId),
            statusKind: "processing"
          });
          this.pollTask(taskId, runId, fallbackExpectedCount);
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
          title: typeof item === "object" && item.label ? item.label : `拍立得 ${index + 1}`,
          downloadStatus: RESULT_DOWNLOAD_STATUS_UNKNOWN,
          saveStatus: RESULT_SAVE_STATUS_UNKNOWN
        };
      })
      .map((image) => this.decorateResultImage(image))
      .filter(Boolean);
  },

  updatePartialImages(images) {
    if (!images.length) return;

    const merged = this.mergeWithLatestResultState(images);
    this.setData({ extractedImages: merged });
    this.prefetchResultImages(merged);
  },

  setExtractedImagesPreservingState(images) {
    const merged = this.mergeWithLatestResultState(images);
    this.setData({ extractedImages: merged });
    return merged;
  },

  mergeWithLatestResultState(images) {
    return this.mergeImages(this.data.extractedImages || [], images || []);
  },

  mergeImages(currentImages, nextImages) {
    const imageMap = {};
    const merged = [];

    currentImages.concat(nextImages).forEach((image) => {
      if (!image || !image.url) return;
      const key = String(image.id || image.url);
      if (imageMap[key]) {
        const target = imageMap[key];
        const previousSaveStatus = imageMap[key].saveStatus;
        const previousDownloadStatus = imageMap[key].downloadStatus;
        const previousLocalPath = imageMap[key].localPath;
        Object.assign(target, image);
        if (previousSaveStatus === RESULT_SAVE_STATUS_SAVED) {
          target.saveStatus = RESULT_SAVE_STATUS_SAVED;
        } else if (previousSaveStatus
          && (!image.saveStatus || image.saveStatus === RESULT_SAVE_STATUS_UNKNOWN)
          && previousSaveStatus !== RESULT_SAVE_STATUS_UNKNOWN) {
          target.saveStatus = previousSaveStatus;
        }
        if (previousDownloadStatus
          && (!image.downloadStatus || image.downloadStatus === RESULT_DOWNLOAD_STATUS_UNKNOWN)
          && previousDownloadStatus !== RESULT_DOWNLOAD_STATUS_UNKNOWN) {
          target.downloadStatus = previousDownloadStatus;
        }
        if (previousLocalPath && !image.localPath) {
          target.localPath = previousLocalPath;
        }
        Object.assign(target, this.decorateResultImage(target));
        return;
      }
      const copy = this.decorateResultImage(Object.assign({
        downloadStatus: RESULT_DOWNLOAD_STATUS_UNKNOWN,
        saveStatus: RESULT_SAVE_STATUS_UNKNOWN
      }, image));
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

  getExpectedPolaroidTarget(payload, fallbackExpectedCount) {
    const userExpectedCount = Number(fallbackExpectedCount || 0);
    if (userExpectedCount > 0) return userExpectedCount;

    const requestedCount = Number(payload.requested_polaroids || payload.requestedPolaroids || 0);
    if (requestedCount > 0) return requestedCount;

    return this.getBackendExpectedCount(payload);
  },

  prefetchResultImages(images) {
    images.forEach((image) => {
      this.enqueueResultDownload(image);
    });
    this.processResultDownloadQueue();
  },

  enqueueResultDownload(image) {
    if (!image || !image.url || image.localPath || image.url.startsWith("wxfile://")) return;
    if (image.downloadStatus === RESULT_DOWNLOAD_STATUS_FAILED) return;
    const key = this.getResultKey(image);
    if (this.downloadingImageUrls[key] || this.queuedResultDownloadKeys[key]) return;

    this.queuedResultDownloadKeys[key] = true;
    this.resultDownloadQueue.push({ key, image: Object.assign({}, image), retryCount: 0 });
    this.updateResultSaveState(image, { downloadStatus: RESULT_DOWNLOAD_STATUS_PENDING });
  },

  processResultDownloadQueue() {
    while (this.activeResultDownloadCount < RESULT_DOWNLOAD_MAX_CONCURRENCY && this.resultDownloadQueue.length) {
      const item = this.resultDownloadQueue.shift();
      delete this.queuedResultDownloadKeys[item.key];
      const image = this.findExtractedImageByKey(item.key);
      if (!image || image.localPath || image.url.startsWith("wxfile://")) continue;

      this.activeResultDownloadCount += 1;
      this.downloadingImageUrls[item.key] = true;
      this.updateResultSaveState(image, { downloadStatus: RESULT_DOWNLOAD_STATUS_DOWNLOADING });
      wx.downloadFile({
        url: image.url,
        header: this.getAuthHeader(),
        success: (res) => {
          const currentImage = this.findCurrentResultForDownload(item);
          if (!currentImage) return;
          if (res.statusCode >= 200 && res.statusCode < 300 && res.tempFilePath) {
            this.updateImageLocalPath(currentImage, res.tempFilePath);
            return;
          }
          this.handleResultDownloadFailure(item, currentImage, res);
        },
        fail: (err) => {
          const currentImage = this.findCurrentResultForDownload(item);
          if (!currentImage) return;
          this.handleResultDownloadFailure(item, currentImage, err);
        },
        complete: () => {
          delete this.downloadingImageUrls[item.key];
          this.activeResultDownloadCount = Math.max(0, this.activeResultDownloadCount - 1);
          this.processResultDownloadQueue();
        }
      });
    }
  },

  handleResultDownloadFailure(item, image, err) {
    console.error("result download failed", err);
    if (item.retryCount < RESULT_DOWNLOAD_MAX_RETRIES) {
      item.retryCount += 1;
      this.queuedResultDownloadKeys[item.key] = true;
      this.resultDownloadQueue.push(item);
      this.updateResultSaveState(image, { downloadStatus: RESULT_DOWNLOAD_STATUS_PENDING });
      return;
    }
    this.updateResultSaveState(image, { downloadStatus: RESULT_DOWNLOAD_STATUS_FAILED });
  },

  updateImageLocalPath(targetImage, localPath) {
    this.updateResultSaveState(targetImage, {
      localPath,
      downloadStatus: RESULT_DOWNLOAD_STATUS_DOWNLOADED
    });
  },

  updateResultSaveState(targetImage, patch) {
    if (!targetImage) return;
    const targetKey = this.getResultKey(targetImage);
    const extractedImages = this.data.extractedImages.map((image) => {
      const key = this.getResultKey(image);
      if (key !== targetKey) return image;
      const nextImage = Object.assign({}, image, patch);
      if (image.saveStatus === RESULT_SAVE_STATUS_SAVED
        && patch.saveStatus
        && patch.saveStatus !== RESULT_SAVE_STATUS_SAVED) {
        nextImage.saveStatus = RESULT_SAVE_STATUS_SAVED;
      }
      return this.decorateResultImage(nextImage);
    });
    this.setData({ extractedImages });
  },

  decorateResultImage(image) {
    if (!image) return image;
    const resultState = image.saveStatus === RESULT_SAVE_STATUS_SAVED
      ? "album"
      : this.getResultLocalPath(image)
        ? "downloaded"
        : "remote";
    return Object.assign({}, image, { resultState });
  },

  getResultLocalPath(image) {
    if (!image) return "";
    if (image.localPath) return image.localPath;
    return image.url && image.url.startsWith("wxfile://") ? image.url : "";
  },

  getResultKey(image) {
    return String(image && (image.id || image.url) || "");
  },

  findExtractedImageByKey(key) {
    return (this.data.extractedImages || []).find((image) => this.getResultKey(image) === key) || null;
  },

  getResultSourceIndex(image) {
    if (image && Number.isInteger(image.sourceImageIndex)) return image.sourceImageIndex;
    if ((this.data.selectedImages || []).length === 1) return 0;
    return Number.isInteger(this.data.currentImageIndex) ? this.data.currentImageIndex : 0;
  },

  getUploadStatusText(imageIndex, totalImages) {
    if (Number.isInteger(imageIndex) && totalImages > 1) {
      return `图片 ${imageIndex + 1}/${totalImages} 图片上传中`;
    }
    return "图片上传中";
  },

  getBackendActiveTaskId(payload) {
    if (!payload || typeof payload !== "object") return "";
    const keys = ["active_task_id", "activeTaskId", "processing_task_id", "processingTaskId", "active_processing_task_id", "activeProcessingTaskId"];
    for (let i = 0; i < keys.length; i += 1) {
      const key = keys[i];
      if (Object.prototype.hasOwnProperty.call(payload, key) && payload[key] !== undefined && payload[key] !== null && payload[key] !== "") {
        return String(payload[key]);
      }
    }
    return "";
  },

  isCurrentTaskActive(payload, taskId) {
    const activeTaskId = this.getBackendActiveTaskId(payload);
    return !!activeTaskId && activeTaskId === String(taskId || "");
  },

  isAnotherTaskActive(payload, taskId) {
    const activeTaskId = this.getBackendActiveTaskId(payload);
    return !!activeTaskId && activeTaskId !== String(taskId || "");
  },

  getQueuePosition(payload) {
    if (!payload || typeof payload !== "object") return "";
    const positionKeys = ["queue_position", "queuePosition", "queue_pos", "position_in_queue"];
    for (let i = 0; i < positionKeys.length; i += 1) {
      const key = positionKeys[i];
      if (Object.prototype.hasOwnProperty.call(payload, key) && payload[key] !== undefined && payload[key] !== null && payload[key] !== "") {
        return String(payload[key]);
      }
    }
    return "";
  },

  getQueuedStatusText(imageIndex, totalImages, payload, taskId) {
    const prefix = Number.isInteger(imageIndex) && totalImages > 1
      ? `图片 ${imageIndex + 1}/${totalImages} `
      : "";
    return this.isAnotherTaskActive(payload, taskId) ? `${prefix}排队等待中` : `${prefix}等待后端处理`;
  },

  getActiveTaskStatusText(imageIndex, totalImages, taskId, payload, doneCount, expectedCount, warning) {
    const prefix = Number.isInteger(imageIndex) && totalImages > 1
      ? `正在处理图片 ${imageIndex + 1}/${totalImages}，`
      : "";
    const phase = String(payload.phase || payload.status || payload.state || "").toLowerCase();
    if (phase === "extracting" || phase === "extraction" || phase.includes("extract")) {
      return prefix
        ? `${prefix}${this.getProcessingStatusText(doneCount, expectedCount, warning)}`
        : this.getProcessingStatusText(doneCount, expectedCount, warning);
    }
    return `${prefix}图片处理中`;
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
      failedImageIndexes: [],
      processing: false,
      showCountInput: false,
      statusText: message || `处理结束，提取了 ${merged.length} 张拍立得`,
      statusKind: "done"
    });
    this.prefetchResultImages(merged);
  },

  finishWithShortage(images, receivedCount, expectedCount) {
    this.clearPollTimer();
    this.activeTaskId = "";
    const merged = this.mergeImages(this.data.extractedImages, images);
    this.setData({
      extractedImages: merged,
      failedImageIndexes: this.data.selectedImages.length ? [this.data.currentImageIndex] : [],
      processing: false,
      showCountInput: false,
      statusText: this.getShortageStatusText(receivedCount, expectedCount),
      statusKind: "error"
    });
    if (merged.length) this.prefetchResultImages(merged);
  },

  finishWithNotice(message) {
    this.clearPollTimer();
    this.activeTaskId = "";
    this.setData({
      processing: false,
      failedImageIndexes: [],
      statusText: message || "处理结束",
      statusKind: "done"
    });
  },

  finishWithError(message) {
    this.clearPollTimer();
    this.activeTaskId = "";
    this.setData({
      processing: false,
      failedImageIndexes: this.data.selectedImages.length ? [this.data.currentImageIndex] : [],
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
      previewPath: path,
      previewRotationDegrees: 0,
      rotationDegrees: 0,
      polaroidSize: DEFAULT_POLAROID_SIZE,
      expectedPolaroidCount: ""
    };
  },

  getCurrentImageState(selectedImages, currentImageIndex) {
    const currentImage = selectedImages[currentImageIndex] || {};
    return {
      inputPath: currentImage.path || currentImage.previewPath || "",
      currentPreviewImages: this.getCurrentPreviewImages(selectedImages, currentImageIndex),
      rotationDegrees: currentImage.rotationDegrees || 0,
      polaroidSize: this.getValidPolaroidSize(currentImage.polaroidSize),
      expectedPolaroidCount: currentImage.expectedPolaroidCount || ""
    };
  },

  getValidPolaroidSize(size) {
    return POLAROID_SIZE_OPTIONS.indexOf(size) >= 0 ? size : DEFAULT_POLAROID_SIZE;
  },

  getValidPostprocessMode(mode) {
    return POSTPROCESS_MODE_OPTIONS.indexOf(mode) >= 0 ? mode : DEFAULT_POSTPROCESS_MODE;
  },

  getDenoiseFormValue(mode) {
    return this.getValidPostprocessMode(mode) === "off" ? "0" : "1";
  },

  getCurrentPreviewImages(selectedImages, currentImageIndex) {
    const currentImage = selectedImages[currentImageIndex] || {};
    const previewPath = currentImage.previewPath || currentImage.path || "";
    if (!previewPath) return [];
    const previewRotationDegrees = currentImage.previewRotationDegrees || currentImage.rotationDegrees || 0;
    return [{
      previewKey: `${currentImage.id || previewPath}-${previewPath}-${previewRotationDegrees}`,
      previewPath,
      previewRotationDegrees
    }];
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

  downloadAllResults() {
    const images = this.data.extractedImages || [];
    if (!images.length) {
      wx.showToast({ title: "暂无结果可下载", icon: "none" });
      return;
    }

    wx.showLoading({ title: "保存中..." });
    let savedCount = 0;
    let failedCount = 0;
    const saveNext = (index) => {
      if (index >= images.length) {
        wx.hideLoading();
        wx.showToast({
          title: failedCount
            ? `已保存 ${savedCount} 张，${failedCount} 张失败`
            : `已保存 ${savedCount} 张`,
          icon: failedCount ? "none" : "success"
        });
        this.setData({
          statusText: failedCount
            ? `保存完成，成功 ${savedCount} 张，失败 ${failedCount} 张`
            : `保存完成，已保存 ${savedCount} 张`,
          statusKind: failedCount ? "error" : "done"
        });
        return;
      }
      const image = images[index];
      const currentImage = this.findExtractedImageByKey(this.getResultKey(image)) || image;
      if (currentImage.saveStatus === RESULT_SAVE_STATUS_SAVED) {
        savedCount += 1;
        saveNext(index + 1);
        return;
      }
      this.updateResultSaveState(currentImage, { saveStatus: RESULT_SAVE_STATUS_SAVING });
      this.setData({
        statusText: `正在保存 ${index + 1}/${images.length}`,
        statusKind: "processing"
      });
      this.saveResultToAlbum(currentImage, (ok) => {
        if (ok) {
          savedCount += 1;
        } else {
          failedCount += 1;
        }
        saveNext(index + 1);
      });
    };

    saveNext(0);
  },

  saveResultToAlbum(image, done) {
    if (!image || !image.url) {
      done(false);
      return;
    }

    const localPath = this.getResultLocalPath(image);
    if (localPath) {
      this.saveImagePathWithRetry(this.getResultKey(image), localPath, 0, done);
      return;
    }

    this.downloadResultForSaveWithRetry(this.getResultKey(image), image.url, 0, (downloadedPath) => {
      if (!downloadedPath) {
        done(false);
        return;
      }
      this.saveImagePathWithRetry(this.getResultKey(image), downloadedPath, 0, done);
    });
  },

  downloadResultForSaveWithRetry(key, url, retryCount, done) {
    const image = this.findExtractedImageByKey(key);
    if (!image || !url) {
      done("");
      return;
    }
    this.updateResultSaveState(image, { downloadStatus: RESULT_DOWNLOAD_STATUS_DOWNLOADING });
    this.downloadResultWithTimeout(url, (result) => {
      const currentImage = this.findExtractedImageByKey(key);
      if (!currentImage) {
        done("");
        return;
      }
      if (result.ok && result.filePath) {
        this.updateImageLocalPath(currentImage, result.filePath);
        done(result.filePath);
        return;
      }
      console.error("save download failed", result.err || result.res || result.reason || result);
      if (retryCount < RESULT_SAVE_MAX_RETRIES) {
        this.updateResultSaveState(currentImage, { downloadStatus: RESULT_DOWNLOAD_STATUS_PENDING });
        this.downloadResultForSaveWithRetry(key, url, retryCount + 1, done);
        return;
      }
      this.updateResultSaveState(currentImage, {
        downloadStatus: RESULT_DOWNLOAD_STATUS_FAILED,
        saveStatus: RESULT_SAVE_STATUS_FAILED
      });
      done("");
    });
  },

  downloadResultWithTimeout(url, done) {
    let settled = false;
    let task = null;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      if (task && typeof task.abort === "function") task.abort();
      done({ ok: false, reason: "timeout" });
    }, RESULT_SAVE_OPERATION_TIMEOUT_MS);
    task = wx.downloadFile({
      url,
      header: this.getAuthHeader(),
      success: (res) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        const ok = res.statusCode >= 200 && res.statusCode < 300 && res.tempFilePath;
        done({ ok: !!ok, filePath: ok ? res.tempFilePath : "", res });
      },
      fail: (err) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        done({ ok: false, err });
      }
    });
  },

  saveImagePathWithRetry(key, filePath, retryCount, done) {
    const image = this.findExtractedImageByKey(key);
    if (!image || !filePath) {
      done(false);
      return;
    }
    this.updateResultSaveState(image, { saveStatus: RESULT_SAVE_STATUS_SAVING });
    this.saveImagePathWithTimeout(filePath, (result) => {
      const currentImage = this.findExtractedImageByKey(key);
      if (!currentImage) {
        done(false);
        return;
      }
      if (result.ok) {
        this.updateResultSaveState(currentImage, { saveStatus: RESULT_SAVE_STATUS_SAVED });
        done(true);
        return;
      }
      if (this.isAlbumAuthDenied(result.err)) {
        this.showAlbumAuthModal();
        this.updateResultSaveState(currentImage, { saveStatus: RESULT_SAVE_STATUS_FAILED });
        done(false);
        return;
      }
      console.error("save image to album failed", result.err || result.reason || result);
      if (retryCount < RESULT_SAVE_MAX_RETRIES) {
        this.saveImagePathWithRetry(key, filePath, retryCount + 1, done);
        return;
      }
      this.updateResultSaveState(currentImage, { saveStatus: RESULT_SAVE_STATUS_FAILED });
      done(false);
    }, () => {
      const currentImage = this.findExtractedImageByKey(key);
      if (currentImage) this.updateResultSaveState(currentImage, { saveStatus: RESULT_SAVE_STATUS_SAVED });
    });
  },

  saveImagePathWithTimeout(filePath, done, onLateSuccess) {
    let doneCalled = false;
    let timedOut = false;
    const timer = setTimeout(() => {
      if (doneCalled) return;
      doneCalled = true;
      timedOut = true;
      done({ ok: false, reason: "timeout" });
    }, RESULT_SAVE_OPERATION_TIMEOUT_MS);
    wx.saveImageToPhotosAlbum({
      filePath,
      success: () => {
        if (timedOut) {
          if (typeof onLateSuccess === "function") onLateSuccess();
          return;
        }
        if (doneCalled) return;
        doneCalled = true;
        clearTimeout(timer);
        done({ ok: true });
      },
      fail: (err) => {
        if (doneCalled) return;
        doneCalled = true;
        clearTimeout(timer);
        done({ ok: false, err });
      }
    });
  },

  isAlbumAuthDenied(err) {
    return !!(err && err.errMsg && err.errMsg.includes("auth deny"));
  },

  showAlbumAuthModal() {
    wx.showModal({
      title: "需要相册权限",
      content: "请在设置中允许保存到相册。",
      confirmText: "去设置",
      success: (res) => {
        if (res.confirm) wx.openSetting();
      }
    });
  },

  getSourceCleanupGroups(sourceIndexes) {
    const indexSet = {};
    (sourceIndexes || []).forEach((index) => {
      if (Number.isInteger(index)) indexSet[index] = true;
    });
    return Object.keys(indexSet).map((indexKey) => {
      const sourceIndex = Number(indexKey);
      return {
        sourceImage: (this.data.selectedImages || [])[sourceIndex],
        results: (this.data.extractedImages || [])
          .filter((image) => this.getResultSourceIndex(image) === sourceIndex)
      };
    });
  },

  getAllSourceCleanupGroups() {
    const selectedImages = this.data.selectedImages || [];
    if (!selectedImages.length) {
      return [{
        sourceImage: null,
        results: this.data.extractedImages || []
      }];
    }
    return selectedImages.map((image, index) => ({
      sourceImage: image,
      results: (this.data.extractedImages || [])
        .filter((result) => this.getResultSourceIndex(result) === index)
    }));
  },

  cleanupRemovedSourceGroups(groups) {
    const localPaths = {};
    const removedResults = [];
    (groups || []).forEach((group) => {
      const sourceImage = group && group.sourceImage;
      this.addLocalCleanupPath(localPaths, sourceImage && sourceImage.path);
      this.addLocalCleanupPath(localPaths, sourceImage && sourceImage.previewPath);
      (group && group.results || []).forEach((result) => {
        removedResults.push(result);
        this.addLocalCleanupPath(localPaths, result && result.localPath);
        if (result && result.url && result.url.startsWith("wxfile://")) {
          this.addLocalCleanupPath(localPaths, result.url);
        }
      });
    });

    this.dropResultDownloadReferences(removedResults);
    Object.keys(localPaths).forEach((filePath) => {
      this.deleteLocalFileBestEffort(filePath);
    });
  },

  addLocalCleanupPath(localPaths, filePath) {
    if (!filePath || !this.isLocalCleanupPath(filePath)) return;
    localPaths[filePath] = true;
  },

  isLocalCleanupPath(filePath) {
    if (!filePath || typeof filePath !== "string") return false;
    return !filePath.startsWith("http://") && !filePath.startsWith("https://");
  },

  deleteLocalFileBestEffort(filePath) {
    const fs = typeof wx.getFileSystemManager === "function" ? wx.getFileSystemManager() : null;
    if (fs && typeof fs.unlink === "function") {
      try {
        fs.unlink({
          filePath,
          fail: (err) => {
            this.removeSavedFileBestEffort(filePath, err);
          }
        });
        return;
      } catch (err) {
        this.removeSavedFileBestEffort(filePath, err);
        return;
      }
    }
    this.removeSavedFileBestEffort(filePath);
  },

  removeSavedFileBestEffort(filePath, unlinkErr) {
    if (typeof wx.removeSavedFile !== "function") {
      if (unlinkErr) console.warn("delete local file failed", filePath, unlinkErr);
      return;
    }
    wx.removeSavedFile({
      filePath,
      fail: (err) => {
        console.warn("delete local file failed", filePath, unlinkErr || err);
      }
    });
  },

  dropResultDownloadReferences(results) {
    const keySet = {};
    (results || []).forEach((image) => {
      const key = this.getResultKey(image);
      if (key) keySet[key] = true;
    });
    if (!Object.keys(keySet).length) return;

    this.resultDownloadQueue = (this.resultDownloadQueue || [])
      .filter((item) => !keySet[item.key]);
    Object.keys(keySet).forEach((key) => {
      delete this.queuedResultDownloadKeys[key];
      delete this.downloadingImageUrls[key];
    });
  },

  findCurrentResultForDownload(item) {
    const image = this.findExtractedImageByKey(item && item.key);
    if (!image || !item || !item.image) return null;
    return image.url === item.image.url ? image : null;
  },

  clearProcessedImages() {
    const selectedImages = this.data.selectedImages || [];
    if (!selectedImages.length) {
      this.resetAllImagesState();
      return;
    }

    const failedIndexSet = {};
    (this.data.failedImageIndexes || []).forEach((index) => {
      failedIndexSet[index] = true;
    });
    const extractedImages = this.data.extractedImages || [];
    const resultsBySourceIndex = {};
    extractedImages.forEach((image) => {
      const sourceIndex = this.getResultSourceIndex(image);
      if (!resultsBySourceIndex[sourceIndex]) resultsBySourceIndex[sourceIndex] = [];
      resultsBySourceIndex[sourceIndex].push(image);
    });

    const preserveSourceIndexSet = {};
    selectedImages.forEach((image, index) => {
      const sourceResults = resultsBySourceIndex[index] || [];
      const hasUnsavedResult = sourceResults.some((result) => result.saveStatus !== RESULT_SAVE_STATUS_SAVED);
      if (failedIndexSet[index] || hasUnsavedResult) {
        preserveSourceIndexSet[index] = true;
      }
    });

    const oldToNewIndex = {};
    const remainingImages = selectedImages.filter((image, index) => {
      if (!preserveSourceIndexSet[index]) return false;
      oldToNewIndex[index] = Object.keys(oldToNewIndex).length;
      return true;
    });

    if (!remainingImages.length) {
      this.resetAllImagesState();
      return;
    }

    const removedSourceIndexes = selectedImages
      .map((image, index) => index)
      .filter((index) => !preserveSourceIndexSet[index]);
    this.cleanupRemovedSourceGroups(this.getSourceCleanupGroups(removedSourceIndexes));

    const remainingExtractedImages = extractedImages
      .filter((image) => preserveSourceIndexSet[this.getResultSourceIndex(image)])
      .map((image) => Object.assign({}, image, {
        sourceImageIndex: oldToNewIndex[this.getResultSourceIndex(image)]
      }));
    const remainingFailedImageIndexes = Object.keys(preserveSourceIndexSet)
      .map((index) => Number(index))
      .filter((index) => failedIndexSet[index])
      .map((index) => oldToNewIndex[index]);

    const nextState = Object.assign(this.getCurrentImageState(remainingImages, 0), {
      selectedImages: remainingImages,
      currentImageIndex: 0,
      extractedImages: remainingExtractedImages,
      failedImageIndexes: remainingFailedImageIndexes,
      processing: false,
      showCountInput: remainingExtractedImages.length === 0,
      statusText: remainingExtractedImages.length
        ? `已清除已保存图片，保留 ${remainingImages.length} 张未完全保存的图片`
        : `已删除成功图片，保留 ${remainingImages.length} 张失败图片`,
      statusKind: remainingExtractedImages.length ? "error" : "ready"
    });
    this.pendingAuthRestoreState = nextState;
    this.setData(nextState);
  },

  resetAllImagesState() {
    this.clearPollTimer();
    this.downloadingImageUrls = {};
    this.cleanupRemovedSourceGroups(this.getAllSourceCleanupGroups());
    this.pendingAuthRestoreState = null;
    this.setData({
      inputPath: "",
      currentPreviewImages: [],
      selectedImages: [],
      currentImageIndex: 0,
      rotationDegrees: 0,
      polaroidSize: DEFAULT_POLAROID_SIZE,
      extractedImages: [],
      failedImageIndexes: [],
      processing: false,
      expectedPolaroidCount: "",
      showCountInput: false,
      statusText: "请选择一张包含拍立得的图片",
      statusKind: "idle"
    });
  },

  saveResult(event) {
    const index = event.currentTarget.dataset.index;
    const image = this.data.extractedImages[index];
    if (!image || !image.url) return;

    if (image.saveStatus === RESULT_SAVE_STATUS_SAVED) {
      wx.showToast({ title: "已保存", icon: "success" });
      return;
    }

    wx.showLoading({ title: "保存中..." });
    this.updateResultSaveState(image, { saveStatus: RESULT_SAVE_STATUS_SAVING });
    this.saveResultToAlbum(image, (ok) => {
      wx.hideLoading();
      if (ok) {
        wx.showToast({ title: "已保存", icon: "success" });
        return;
      }
      this.setData({
        statusText: "保存失败，请重试",
        statusKind: "error"
      });
      wx.showToast({ title: "保存失败", icon: "none" });
    });
  },

  clearPollTimer() {
    if (this.pollTimer) {
      clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }
  }
});
