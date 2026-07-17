const {
  AUTH_STORAGE_KEY,
  SCANNER_AUTH_PASSED_KEY,
  USER_SESSION_STORAGE_KEY,
  API_GATEWAY_BASE_URL,
  getApiBaseUrl,
  getStoredUserSession,
  getUserSessionHeader,
  isLocalPreviewToken
} = require("../../utils/config");
const {
  getLocalUserDataBundle,
  getLocalUserDataSyncMeta,
  saveLocalUserDataSyncMeta
} = require("../../utils/local-user-data");

const WECHAT_LOGIN_PATH = "/api/auth/wechat-login";
const USER_DATA_SYNC_PATH = "/api/user-data";
const CONTACT_MESSAGE_MAX_LENGTH = 1000;
const CONTACT_INFO_MAX_LENGTH = 200;

function formatSessionExpiry(value) {
  if (!value) return "";
  const raw = String(value);
  const numeric = Number(raw);
  const timestamp = Number.isFinite(numeric)
    ? (numeric < 1000000000000 ? numeric * 1000 : numeric)
    : Date.parse(raw);
  if (!Number.isFinite(timestamp)) return raw;
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return raw;
  return date.toLocaleString();
}

Page({
  data: {
    hasUserSession: false,
    userSessionUserId: "",
    userSessionExpiresAt: "",
    wechatLoggingIn: false,
    wechatLoginStatus: "",
    wechatLoginStatusKind: "idle",
    syncSubmitting: false,
    syncStatus: "Manual sync uploads local data after WeChat login.",
    syncStatusKind: "idle",
    syncCloudHash: "",
    syncLastSyncedHash: "",
    syncLastSyncedAt: "",
    showContactDialog: false,
    contactMessage: "",
    contactInfo: "",
    contactSubmitting: false
  },

  onShow() {
    this.setTabBarSelected(4);
    this.loadUserSessionState();
  },

  setTabBarSelected(selected) {
    if (typeof this.getTabBar !== "function") return;
    const tabBar = this.getTabBar();
    if (tabBar) tabBar.setData({ selected });
  },

  returnToAuth() {
    wx.removeStorageSync(AUTH_STORAGE_KEY);
    wx.removeStorageSync(SCANNER_AUTH_PASSED_KEY);
    wx.reLaunch({ url: "/pages/auth/auth" });
  },

  loadUserSessionState() {
    const session = getStoredUserSession();
    const hasUserSession = !!(session && session.token);
    const syncMeta = getLocalUserDataSyncMeta();
    this.setData({
      hasUserSession,
      userSessionUserId: hasUserSession ? (session.userId || "") : "",
      userSessionExpiresAt: hasUserSession ? formatSessionExpiry(session.expiresAt) : "",
      wechatLoginStatus: hasUserSession ? "微信身份已登录" : "可在这里登录微信身份",
      wechatLoginStatusKind: hasUserSession ? "success" : "idle",
      syncCloudHash: syncMeta.cloudHash,
      syncLastSyncedHash: syncMeta.lastSyncedHash,
      syncLastSyncedAt: formatSessionExpiry(syncMeta.lastSyncedAt)
    });
  },

  loginWithWeChat() {
    if (this.data.wechatLoggingIn) return;

    this.setData({
      wechatLoggingIn: true,
      wechatLoginStatus: "微信登录中...",
      wechatLoginStatusKind: "loading"
    });

    wx.login({
      success: (loginRes) => {
        const code = loginRes && loginRes.code ? loginRes.code : "";
        if (!code) {
          this.setWechatLoginError("微信登录未返回临时代码，请重试。");
          return;
        }
        this.requestUserSession(code);
      },
      fail: (err) => {
        const errMsg = err && err.errMsg ? err.errMsg : "";
        this.setWechatLoginError(errMsg ? `微信登录失败：${errMsg}` : "微信登录失败，请重试。");
      }
    });
  },

  requestUserSession(code) {
    this.setData({
      wechatLoginStatus: "正在建立用户身份...",
      wechatLoginStatusKind: "loading"
    });

    wx.request({
      url: `${API_GATEWAY_BASE_URL}${WECHAT_LOGIN_PATH}`,
      method: "POST",
      header: { "content-type": "application/json" },
      data: { code },
      success: (res) => {
        const ok = res.statusCode >= 200
          && res.statusCode < 300
          && res.data
          && (res.data.ok !== false);

        if (!ok) {
          this.setWechatLoginError((res.data && (res.data.error || res.data.message)) || "用户身份建立失败，请重试。");
          return;
        }

        const session = this.normalizeUserSession(res.data);
        if (!session) {
          this.setWechatLoginError("后端未返回有效用户会话，请重试。");
          return;
        }

        wx.setStorageSync(USER_SESSION_STORAGE_KEY, session);
        this.setData({
          wechatLoggingIn: false,
          hasUserSession: true,
          userSessionUserId: session.userId || "",
          userSessionExpiresAt: formatSessionExpiry(session.expiresAt),
          wechatLoginStatus: "微信身份已登录",
          wechatLoginStatusKind: "success"
        });
      },
      fail: (err) => {
        const errMsg = err && err.errMsg ? err.errMsg : "";
        this.setWechatLoginError(errMsg ? `无法连接登录服务：${errMsg}` : "无法连接登录服务，请检查网络后重试。");
      }
    });
  },

  normalizeUserSession(responseData) {
    const payload = responseData && (responseData.session || responseData.data || responseData);
    if (!payload) return null;

    const token = payload.user_session_token
      || payload.userSessionToken
      || payload.session_token
      || payload.sessionToken
      || payload.token
      || "";

    if (!token) return null;

    return {
      token,
      userId: payload.user_id || payload.userId || "",
      expiresAt: payload.expires_at || payload.expiresAt || "",
      issuedAt: Date.now()
    };
  },

  setWechatLoginError(message) {
    this.setData({
      wechatLoggingIn: false,
      wechatLoginStatus: message,
      wechatLoginStatusKind: "error"
    });
  },

  syncLocalUserData() {
    if (this.data.syncSubmitting) return;

    const session = getStoredUserSession();
    if (!session || !session.token) {
      wx.showModal({
        title: "WeChat login required",
        content: "Please log in with WeChat in Settings before syncing local data.",
        confirmText: "Log in",
        cancelText: "Cancel",
        success: (res) => {
          if (res.confirm) this.loginWithWeChat();
        }
      });
      return;
    }

    const syncMeta = getLocalUserDataSyncMeta();
    const payload = {
      baseHash: syncMeta.cloudHash || syncMeta.lastSyncedHash || "",
      data: getLocalUserDataBundle()
    };

    this.setData({
      syncSubmitting: true,
      syncStatus: "Syncing local data...",
      syncStatusKind: "loading"
    });

    wx.request({
      url: `${API_GATEWAY_BASE_URL}${USER_DATA_SYNC_PATH}`,
      method: "PUT",
      header: Object.assign(
        { "content-type": "application/json", Accept: "application/json" },
        getUserSessionHeader()
      ),
      data: payload,
      success: (res) => {
        if (res.statusCode === 409) {
          const conflict = this.parseMaybeJson(res.data) || {};
          const cloudHash = conflict.cloudHash || "";
          this.setData({
            syncSubmitting: false,
            syncStatus: cloudHash
              ? `Sync conflict. Cloud hash: ${cloudHash}`
              : "Sync conflict. Local data was not changed.",
            syncStatusKind: "error"
          });
          return;
        }

        const responseData = this.parseMaybeJson(res.data) || {};
        const ok = res.statusCode >= 200
          && res.statusCode < 300
          && responseData
          && (responseData.ok !== false);

        if (!ok) {
          this.setData({
            syncSubmitting: false,
            syncStatus: this.getSyncErrorMessage(responseData) || "Sync failed. Local data was not changed.",
            syncStatusKind: "error"
          });
          return;
        }

        const nested = responseData.data && typeof responseData.data === "object" ? responseData.data : {};
        const cloudHash = responseData.cloudHash || responseData.hash || nested.cloudHash || nested.hash || "";
        const syncedAt = responseData.updatedAt
          || responseData.updated_at
          || nested.updatedAt
          || nested.updated_at
          || new Date().toISOString();
        const savedMeta = saveLocalUserDataSyncMeta({
          cloudHash,
          lastSyncedHash: cloudHash,
          lastSyncedAt: syncedAt
        });

        this.setData({
          syncSubmitting: false,
          syncStatus: "Sync complete.",
          syncStatusKind: "success",
          syncCloudHash: savedMeta.cloudHash,
          syncLastSyncedHash: savedMeta.lastSyncedHash,
          syncLastSyncedAt: formatSessionExpiry(savedMeta.lastSyncedAt)
        });
      },
      fail: (err) => {
        const errMsg = err && err.errMsg ? err.errMsg : "";
        this.setData({
          syncSubmitting: false,
          syncStatus: errMsg ? `Sync failed: ${errMsg}` : "Sync failed. Local data was not changed.",
          syncStatusKind: "error"
        });
      }
    });
  },

  parseMaybeJson(data) {
    if (typeof data !== "string") return data;
    try {
      return JSON.parse(data);
    } catch (e) {
      return data;
    }
  },

  getSyncErrorMessage(data) {
    if (!data) return "";
    if (typeof data === "string") return data;
    return data.message || data.error || data.errorMessage || "";
  },

  contactAuthor() {
    this.setData({
      showContactDialog: true,
      contactMessage: "",
      contactInfo: "",
      contactSubmitting: false
    });
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
    const token = wx.getStorageSync(AUTH_STORAGE_KEY) || "";
    const apiBaseUrl = getApiBaseUrl(token);
    if (!token || !apiBaseUrl || isLocalPreviewToken(token)) {
      wx.showToast({ title: "请先验证有效的 Scanner Token", icon: "none" });
      return;
    }

    this.setData({ contactSubmitting: true });
    wx.request({
      url: `${apiBaseUrl}/api/contact`,
      method: "POST",
      header: Object.assign({
        "content-type": "application/json",
        "X-Cheki-Token": token
      }, getUserSessionHeader()),
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
          title: "发送失败，请稍后重试",
          icon: "none"
        });
      },
      fail: () => {
        this.setData({ contactSubmitting: false });
        wx.showToast({ title: "发送失败，请稍后重试", icon: "none" });
      }
    });
  },

  openLianliankan() {
    wx.navigateTo({ url: "/pages/lianliankan/lianliankan" });
  },

  openXiaoxiaole() {
    wx.navigateTo({ url: "/pages/xiaoxiaole/xiaoxiaole" });
  },

  openIzaya7Map() {
    wx.navigateTo({ url: "/pages/izaya7-map/izaya7-map" });
  }
});
