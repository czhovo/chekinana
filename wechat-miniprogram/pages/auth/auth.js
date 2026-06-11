const { AUTH_STORAGE_KEY, getApiBaseUrl, setApiBaseUrl } = require("../../utils/config");

Page({
  data: {
    apiBaseUrl: "",
    token: "",
    hideToken: true,
    verifying: false,
    errorText: ""
  },

  onLoad() {
    const token = wx.getStorageSync(AUTH_STORAGE_KEY) || "";
    this.setData({
      apiBaseUrl: getApiBaseUrl(),
      token
    });
  },

  onApiBaseUrlInput(event) {
    this.setData({
      apiBaseUrl: (event.detail.value || "").trim(),
      errorText: ""
    });
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
    const token = (this.data.token || "").trim();
    const apiBaseUrl = (this.data.apiBaseUrl || "").trim().replace(/\/+$/, "");
    if (!token || this.data.verifying) return;

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

        setApiBaseUrl(apiBaseUrl);
        wx.setStorageSync(AUTH_STORAGE_KEY, token);
        wx.redirectTo({ url: "/pages/index/index" });
      },
      fail: () => {
        this.setData({
          verifying: false,
          errorText: "无法连接服务器，请检查后端是否已启动。"
        });
      }
    });
  }
});
