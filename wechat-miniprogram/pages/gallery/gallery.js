Page({
  onShow() {
    this.setTabBarSelected(3);
  },

  setTabBarSelected(selected) {
    if (typeof this.getTabBar !== "function") return;
    const tabBar = this.getTabBar();
    if (tabBar) tabBar.setData({ selected });
  }
});
