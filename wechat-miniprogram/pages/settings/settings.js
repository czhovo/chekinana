const { AUTH_STORAGE_KEY, SCANNER_AUTH_PASSED_KEY } = require("../../utils/config");

Page({
  onShow() {
    this.setTabBarSelected(4);
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

  openLianliankan() {
    wx.navigateTo({ url: "/pages/lianliankan/lianliankan" });
  },

  openIzaya7Map() {
    wx.navigateTo({ url: "/pages/izaya7-map/izaya7-map" });
  }
});
