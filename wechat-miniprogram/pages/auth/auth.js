const { AUTH_STORAGE_KEY, SCANNER_AUTH_PASSED_KEY, getApiBaseUrl, isLocalPreviewToken, normalizePodId } = require("../../utils/config");

Page({
  data: {
    token: "",
    hideToken: true,
    verifying: false,
    errorText: ""
  },

  onLoad() {
    const token = wx.getStorageSync(AUTH_STORAGE_KEY) || "";
    if (token && !isLocalPreviewToken(token)) {
      this.setData({ token });
    }
  },

  onTokenInput(event) {
    this.setData({
      token: (event.detail.value || "").trim(),
      errorText: ""
    });
  },

  toggleHideToken() {
    this.setData({
      hideToken: !this.data.hideToken
    });
  },

  verifyToken() {
    const rawToken = this.data.token;
    if (rawToken === "calendar") {
      wx.switchTab({ url: "/pages/calendar/calendar" });
      return;
    }

    const token = normalizePodId(rawToken);
    const apiBaseUrl = getApiBaseUrl(token);
    if (!token || this.data.verifying) return;

    if (isLocalPreviewToken(token)) {
      wx.setStorageSync(AUTH_STORAGE_KEY, token);
      wx.setStorageSync(SCANNER_AUTH_PASSED_KEY, "1");
      wx.switchTab({ url: "/pages/index/index" });
      return;
    }

    if (!apiBaseUrl) {
      this.setData({ errorText: "请先配置后端地址。" });
      return;
    }

    this.setData({
      verifying: true,
      errorText: ""
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
        const ok = res.statusCode >= 200
          && res.statusCode < 300
          && res.data
          && (res.data.ok === true || res.data.valid === true || res.data.status === "ok");

        if (!ok) {
          this.setData({
            verifying: false,
            errorText: (res.data && (res.data.error || res.data.message)) || "Token 验证失败。"
          });
          return;
        }

        wx.setStorageSync(AUTH_STORAGE_KEY, token);
        wx.setStorageSync(SCANNER_AUTH_PASSED_KEY, "1");
        wx.switchTab({ url: "/pages/index/index" });
      },
      fail: (err) => {
        const errMsg = err && err.errMsg ? err.errMsg : "";
        this.setData({
          verifying: false,
          errorText: errMsg ? `无法连接服务器：${errMsg}` : "无法连接服务器，请检查后端是否已启动。"
        });
      }
    });
  }
});
